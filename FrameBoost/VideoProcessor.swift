import Foundation
import AVFoundation
import CoreImage
import Vision

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

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        try await process(url: url, options: VideoProcessingOptions(targetFPS: 60), progress: progress)
    }

    func process(url: URL, options: VideoProcessingOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 60.0
        let oriented = naturalSize.applying(transform)
        let sourceWidth = even(max(Int(abs(oriented.width).rounded()), 2))
        let sourceHeight = even(max(Int(abs(oriented.height).rounded()), 2))
        let width = even(max(options.exportWidth ?? sourceWidth, 2))
        let height = even(max(options.exportHeight ?? sourceHeight, 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        defer { if FileManager.default.fileExists(atPath: outputURL.path) { try? FileManager.default.removeItem(at: outputURL) } }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: options.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: 120]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read selected video") }

        var lastWrittenTime = CMTime.invalid
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let image = normalizedImage(CIImage(cvPixelBuffer: buffer), transform: transform)
                do {
                    // For this release, the application is explicitly 60 FPS focused.
                    // Preserve the source cadence when it is already 60 FPS and avoid
                    // holding previous/current CIImage graphs across loop iterations.
                    if sourceFPS >= 59.0 {
                        if time > lastWrittenTime {
                            try appendSync(image, at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = time
                        }
                    } else {
                        // Non-60 sources are intentionally not interpolated here.
                        // They are rejected rather than creating expensive frame graphs.
                        throw makeError("FrameBoost currently requires a 60 FPS source")
                    }
                } catch {
                    reader.cancelReading()
                    writer.cancelWriting()
                }
                progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
            }
            if reader.status == .cancelled || writer.status == .cancelled {
                throw writer.error ?? makeError("Video processing stopped")
            }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? makeError("Video reader failed") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        progress(1)
        return outputURL
    }

    private func normalizedImage(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let transformed = image.transformed(by: transform)
        let e = transformed.extent
        return transformed.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
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
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sx = CGFloat(width) / max(normalized.extent.width, 1)
        let sy = CGFloat(height) / max(normalized.extent.height, 1)
        let finalImage = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.render(finalImage, to: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
