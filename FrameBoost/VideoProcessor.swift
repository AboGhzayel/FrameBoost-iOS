import Foundation
import AVFoundation
import CoreImage

struct VideoProcessingOptions: Sendable {
    var targetFPS: Int = 60
    var exportWidth: Int?
    var exportHeight: Int?
    var bitrate: Int = 10_000_000
    var forceSDR: Bool = false
    var motionBlur: Bool = false
    var motionBlurStrength: CGFloat = 0.0
}

final class VideoProcessor {
    private let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    private let rife = RIFEEngine()

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        try await process(url: url, options: VideoProcessingOptions(targetFPS: targetFPS), progress: progress)
    }

    func process(url: URL, options: VideoProcessingOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30.0
        let oriented = naturalSize.applying(transform)
        let sourceWidth = even(max(Int(abs(oriented.width).rounded()), 2))
        let sourceHeight = even(max(Int(abs(oriented.height).rounded()), 2))
        let width = even(max(options.exportWidth ?? sourceWidth, 2))
        let height = even(max(options.exportHeight ?? sourceHeight, 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }

        let reader = try AVAssetReader(asset: asset)
        // Decode directly to BGRA. This avoids relying on Core Image's YUV conversion
        // during export and prevents black frames on devices/codecs with unusual range metadata.
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 120,
            AVVideoExpectedSourceFrameRateKey: 60
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read selected video") }

        var previousBuffer: CVPixelBuffer?
        var previousTime = CMTime.invalid
        var lastWrittenTime = CMTime.invalid
        var frameIndex = 0

        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var processingError: Error?

            autoreleasepool {
                do {
                    if sourceFPS >= 59.0 {
                        let image = CIImage(cvPixelBuffer: buffer)
                        try appendSync(image, at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                        lastWrittenTime = time
                    } else if sourceFPS >= 20.0 {
                        if let previousBuffer, previousTime.isValid, time > previousTime {
                            if rife.isAvailable {
                                do {
                                    let generated = try rife.interpolate(first: previousBuffer, second: buffer)
                                    try appendSync(CIImage(cvPixelBuffer: generated), at: CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(time - previousTime, multiplier: 0.5)), adaptor: adaptor, writer: writer, width: width, height: height)
                                } catch {
                                    // Fall back to the source frame if RIFE is unavailable/incompatible.
                                }
                            }
                            try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = time
                        } else {
                            let outputTime = CMTime(value: Int64(frameIndex) * 2, timescale: 60)
                            try appendSync(CIImage(cvPixelBuffer: buffer), at: outputTime, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = outputTime
                        }
                    } else {
                        throw makeError("Unsupported source frame rate")
                    }
                    previousBuffer = buffer
                    previousTime = time
                    frameIndex += 1
                } catch let caughtError {
                    processingError = caughtError
                }
                progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
            }

            if let processingError {
                reader.cancelReading()
                writer.cancelWriting()
                throw processingError
            }
            if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
            if writer.status == .failed { throw writer.error ?? makeError("Video writer failed") }
        }

        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? makeError("Video reader failed") }
        if writer.status == .cancelled { throw writer.error ?? makeError("Video writer cancelled") }
        if writer.status == .failed { throw writer.error ?? makeError("Video writer failed") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        completed = true
        progress(1)
        return outputURL
    }

    private func appendSync(_ image: CIImage, at time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, width: Int, height: Int) throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? makeError("Video writer stopped") }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard let pool = adaptor.pixelBufferPool else { throw makeError("Pixel buffer pool unavailable") }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw makeError("Unable to allocate video frame (code \(result))") }
        autoreleasepool {
            let e = image.extent.integral
            guard e.width > 0, e.height > 0 else { return }
            let normalized = image.cropped(to: e)
            let sx = CGFloat(width) / e.width
            let sy = CGFloat(height) / e.height
            let finalImage = normalized.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.render(finalImage, to: buffer!)
        }
        guard adaptor.append(buffer!, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
