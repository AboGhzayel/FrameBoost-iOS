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
    private let artifactReduction = ArtifactReduction()

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        try await process(url: url, options: VideoProcessingOptions(targetFPS: targetFPS), progress: progress)
    }

    /// Re-encodes the source locally before AI upload/processing. This keeps cloud uploads
    /// predictable and gives the AI a clean, constant-frame-rate input.
    func preprocess(url: URL, profile: PreprocessingProfile, progress: @escaping (Double) -> Void) async throws -> URL {
        if profile == .motionBlur {
            return try await reencode(url: url, bitrate: profile.bitrate, frameRate: profile.frameRate, temporalBlend: profile.blurStrength, progress: progress)
        }
        return try await reencode(url: url, bitrate: profile.bitrate, frameRate: profile.frameRate, temporalBlend: 0, progress: progress)
    }

    private func reencode(url: URL, bitrate: Int, frameRate: Int, temporalBlend: Float, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = max(CMTimeGetSeconds(try await asset.load(.duration)), 0.001)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let width = even(max(Int(abs(size.width.rounded())), 2))
        let height = even(max(Int(abs(size.height.rounded())), 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-Preprocessed-\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2
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
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start preprocessing export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read source") }

        var previous: CIImage?
        var nextOutputTime = CMTime.zero
        let outputFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: buffer)
                var prepared = image
                if let previous, temporalBlend > 0 {
                    prepared = image.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: previous])
                    prepared = prepared.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.0])
                }
                do {
                    try appendSync(prepared, at: nextOutputTime, adaptor: adaptor, writer: writer, width: width, height: height)
                } catch { reader.cancelReading(); writer.cancelWriting() }
                previous = image
                nextOutputTime = nextOutputTime + outputFrameDuration
            }
            progress(min(max(CMTimeGetSeconds(sourceTime) / duration, 0), 1))
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? makeError("Preprocessing reader failed") }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Preprocessing export failed") }
        progress(1)
        return outputURL
    }

    func process(url: URL, options: VideoProcessingOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30.0
        let oriented = naturalSize.applying(try await track.load(.preferredTransform))
        let sourceWidth = even(max(Int(abs(oriented.width).rounded()), 2))
        let sourceHeight = even(max(Int(abs(oriented.height).rounded()), 2))
        let width = even(max(options.exportWidth ?? sourceWidth, 2))
        let height = even(max(options.exportHeight ?? sourceHeight, 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        readerOutput.alwaysCopiesSampleData = false; reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: options.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: 120, AVVideoExpectedSourceFrameRateKey: 60]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }; writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read selected video") }
        var previousBuffer: CVPixelBuffer?; var previousTime = CMTime.invalid
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation(); guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample); var processingError: Error?
            autoreleasepool {
                do {
                    if sourceFPS >= 59.0 { try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height) }
                    else if sourceFPS >= 20.0 {
                        guard let previousBuffer, previousTime.isValid, time > previousTime else { try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height); previousBuffer = buffer; previousTime = time; return }
                        guard rife.isAvailable else { throw makeError("RIFE Core ML model is unavailable; 30→60 requires the bundled model") }
                        let generated = try rife.interpolate(first: previousBuffer, second: buffer)
                        let stabilized = artifactReduction.stabilize(generated: generated, first: previousBuffer, second: buffer) ?? generated
                        let midpoint = CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(time - previousTime, multiplier: 0.5))
                        try appendSync(CIImage(cvPixelBuffer: stabilized), at: midpoint, adaptor: adaptor, writer: writer, width: width, height: height)
                        try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                    } else { throw makeError("Unsupported source frame rate") }
                    previousBuffer = buffer; previousTime = time
                } catch { processingError = error }
                progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
            }
            if let processingError { reader.cancelReading(); writer.cancelWriting(); throw processingError }
            if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
            if writer.status == .failed { throw writer.error ?? makeError("Video writer failed") }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? makeError("Video reader failed") }
        if writer.status == .cancelled { throw makeError("Video writer cancelled") }
        if writer.status == .failed { throw writer.error ?? makeError("Video writer failed") }
        input.markAsFinished(); await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        completed = true; progress(1); return outputURL
    }

    private func appendSync(_ image: CIImage, at time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, width: Int, height: Int) throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData { if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? makeError("Video writer stopped") }; Thread.sleep(forTimeInterval: 0.001) }
        guard let pool = adaptor.pixelBufferPool else { throw makeError("Pixel buffer pool unavailable") }
        var outputBuffer: CVPixelBuffer?; let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard result == kCVReturnSuccess, let outputBuffer else { throw makeError("Unable to allocate video frame (code \(result))") }
        let extent = image.extent.integral; guard extent.width > 0, extent.height > 0 else { throw makeError("Invalid video frame extent") }
        autoreleasepool { let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)); let sx = CGFloat(width) / extent.width; let sy = CGFloat(height) / extent.height; let finalImage = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))); context.render(finalImage, to: outputBuffer) }
        guard adaptor.append(outputBuffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }
    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
