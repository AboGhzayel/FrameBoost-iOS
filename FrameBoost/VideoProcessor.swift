import Foundation
import AVFoundation
import CoreImage

enum VideoColorMode: Sendable { case automatic, forceSDR }

struct VideoProcessingOptions: Sendable {
    var targetFPS: Int = 60
    var exportWidth: Int?
    var exportHeight: Int?
    var bitrate: Int = 10_000_000
    var forceSDR: Bool = false
    var colorMode: VideoColorMode = .automatic
    var motionBlur: Bool = false
    var motionBlurStrength: CGFloat = 0.0
    var codec: AVVideoCodecType = .h264
    var profileLevel: String = AVVideoProfileLevelH264HighAutoLevel
    var preserveSourceFPS: Bool = true
    var colorPrimaries: String = AVVideoColorPrimaries_ITU_R_709_2
    var transferFunction: String = AVVideoTransferFunction_ITU_R_709_2
    var yCbCrMatrix: String = AVVideoYCbCrMatrix_ITU_R_709_2
}

final class VideoProcessor {
    private let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    private let rife = RIFEEngine()
    private let artifactReduction = ArtifactReduction()

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        try await process(url: url, options: VideoProcessingOptions(targetFPS: targetFPS), progress: progress)
    }

    func preprocess(url: URL, profile: PreprocessingProfile, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let sourceFPS = try await track.load(.nominalFrameRate)
        let fps = max(Int(sourceFPS.rounded()), 1)
        var options = VideoProcessingOptions(targetFPS: fps, bitrate: profile.bitrate)
        if profile == .motionBlur { options.motionBlur = true; options.motionBlurStrength = CGFloat(profile.blurStrength) }
        return try await reencode(url: url, options: options, progress: progress)
    }

    private func reencode(url: URL, options: VideoProcessingOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = max(CMTimeGetSeconds(try await asset.load(.duration)), 0.001)
        let sourceFPS = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let width = even(max(Int(abs(size.width.rounded())), 2))
        let height = even(max(Int(abs(size.height.rounded())), 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-Preprocessed-\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        ro.alwaysCopiesSampleData = true
        reader.add(ro)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let fps = max(Int(sourceFPS.rounded()), 1)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: options.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA, String(kCVPixelBufferWidthKey): width, String(kCVPixelBufferHeightKey): height, String(kCVPixelBufferIOSurfacePropertiesKey): [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start preprocessing export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read source") }
        let ci = CIContext(options: [CIContextOption.cacheIntermediates: false])
        while let sample = ro.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var image = CIImage(cvPixelBuffer: buffer)
            if options.motionBlur { image = image.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: CGFloat(options.motionBlurStrength), kCIInputAngleKey: 0.0]) }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw makeError("Pixel buffer pool unavailable") }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { throw makeError("Unable to allocate preprocessing frame") }
            renderAspectFill(image, to: out, width: width, height: height, context: ci)
            guard adaptor.append(out, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append preprocessing frame") }
            progress(min(max(CMTimeGetSeconds(time) / duration, 0), 1))
        }
        if reader.status == .failed { throw reader.error ?? makeError("Preprocessing reader failed") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Preprocessing export failed") }
        progress(1)
        return outputURL
    }

    func process(url: URL, options: VideoProcessingOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = max(CMTimeGetSeconds(try await asset.load(.duration)), 0.001)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30
        let naturalSize = try await track.load(.naturalSize)
        let oriented = naturalSize.applying(try await track.load(.preferredTransform))
        let sourceWidth = even(max(Int(abs(oriented.width).rounded()), 2))
        let sourceHeight = even(max(Int(abs(oriented.height).rounded()), 2))
        let width = even(max(options.exportWidth ?? sourceWidth, 2))
        let height = even(max(options.exportHeight ?? sourceHeight, 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }

        let reader = try AVAssetReader(asset: asset)
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        ro.alwaysCopiesSampleData = true
        reader.add(ro)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let exportFPS = max(options.targetFPS, 1)
        let profile: String? = options.codec == AVVideoCodecType.hevc ? nil : options.profileLevel
        var compression: [String: Any] = [AVVideoAverageBitRateKey: options.bitrate, AVVideoMaxKeyFrameIntervalKey: exportFPS * 2, AVVideoExpectedSourceFrameRateKey: exportFPS, AVVideoAllowFrameReorderingKey: true]
        if let profile { compression[AVVideoProfileLevelKey] = profile }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: options.codec, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA, String(kCVPixelBufferWidthKey): width, String(kCVPixelBufferHeightKey): height, String(kCVPixelBufferIOSurfacePropertiesKey): [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? makeError("Unable to read selected video") }

        var previousBuffer: CVPixelBuffer?
        var previousTime = CMTime.invalid
        while let sample = ro.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var processingError: Error?
            autoreleasepool {
                do {
                    if sourceFPS >= 59 && options.preserveSourceFPS {
                        try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                    } else if sourceFPS >= 20 {
                        if let previousBuffer, previousTime.isValid, time > previousTime {
                            guard rife.isAvailable else { throw makeError("RIFE Core ML model is unavailable") }
                            let generated = try rife.interpolate(first: previousBuffer, second: buffer)
                            let stabilized = artifactReduction.stabilize(generated: generated, first: previousBuffer, second: buffer) ?? generated
                            let midpoint = CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(time - previousTime, multiplier: 0.5))
                            try appendSync(CIImage(cvPixelBuffer: stabilized), at: midpoint, adaptor: adaptor, writer: writer, width: width, height: height)
                        }
                        try appendSync(CIImage(cvPixelBuffer: buffer), at: time, adaptor: adaptor, writer: writer, width: width, height: height)
                    } else {
                        throw makeError("Unsupported source frame rate")
                    }
                } catch { processingError = error }
            }
            if let processingError { reader.cancelReading(); writer.cancelWriting(); throw processingError }
            previousBuffer = buffer; previousTime = time
            progress(min(max(CMTimeGetSeconds(time) / duration, 0), 1))
            if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
        }
        if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
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
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess, let outputBuffer else { throw makeError("Unable to allocate video frame") }
        renderAspectFill(image, to: outputBuffer, width: width, height: height, context: context)
        guard adaptor.append(outputBuffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func renderAspectFill(_ image: CIImage, to output: CVPixelBuffer, width: Int, height: Int, context: CIContext) {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let crop = CGRect(x: scaledExtent.midX - CGFloat(width) / 2, y: scaledExtent.midY - CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height))
        // CIImage can retain a non-zero origin after cropping. Normalize the
        // crop to (0,0) before rendering into the pixel buffer; otherwise the
        // requested bounds may not intersect the image and the destination can
        // remain black.
        let normalized = scaled.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        context.render(normalized, to: output, bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
