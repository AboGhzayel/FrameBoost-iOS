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
    private let opticalFlow = OpticalFlowEngine()

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
        let sourceFPS = nominal > 0 ? Double(nominal) : 60.0
        let fps = 60.0
        let oriented = naturalSize.applying(transform)
        let sourceWidth = even(max(Int(abs(oriented.width).rounded()), 2))
        let sourceHeight = even(max(Int(abs(oriented.height).rounded()), 2))
        let width = even(max(options.exportWidth ?? sourceWidth, 2))
        let height = even(max(options.exportHeight ?? sourceHeight, 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: options.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? makeError("Unable to read selected video") }

        var previous: Frame?
        var lastWrittenTime = CMTime.invalid
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let current = Frame(pixelBuffer: buffer, image: normalizedImage(CIImage(cvPixelBuffer: buffer), transform: transform), time: time)
            if let previous {
                let delta = CMTimeGetSeconds(time - previous.time)
                if delta > 0.0001 && delta < 1.0 {
                    // 60 FPS is the only output mode. Never create extra frames
                    // when the source is already 60 FPS: preserve its timestamps.
                    if sourceFPS >= 59.0 {
                        if previous.time > lastWrittenTime {
                            try await append(previous.image, at: previous.time, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = previous.time
                        }
                    } else {
                        // Non-60 input is normalized to a 60 FPS timeline. Optical-flow
                        // generation remains bounded to one interval at a time.
                        let count = min(max(Int((delta * fps).rounded()), 1), 8)
                        if previous.time > lastWrittenTime {
                            try await append(previous.image, at: previous.time, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = previous.time
                        }
                        if count > 1 {
                            let motion = autoreleasepool { try? opticalFlow.estimate(from: previous.pixelBuffer, to: current.pixelBuffer) }
                            for i in 1..<count {
                                let f = CGFloat(i) / CGFloat(count)
                                let candidate = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(time - previous.time, multiplier: Double(f)))
                                guard candidate > lastWrittenTime else { continue }
                                let intermediate = makeIntermediate(previous: previous.image, current: current.image, motion: motion, fraction: f)
                                try await append(intermediate, at: candidate, adaptor: adaptor, writer: writer, width: width, height: height)
                                lastWrittenTime = candidate
                            }
                        }
                    }
                }
            } else {
                try await append(current.image, at: .zero, adaptor: adaptor, writer: writer, width: width, height: height)
                lastWrittenTime = .zero
            }
            previous = current
            progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
        }
        if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
        if let previous, previous.time > lastWrittenTime {
            try await append(previous.image, at: previous.time, adaptor: adaptor, writer: writer, width: width, height: height)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        progress(1)
        return outputURL
    }

    private func makeIntermediate(previous: CIImage, current: CIImage, motion: OpticalFlowEngine.Motion?, fraction: CGFloat) -> CIImage {
        guard let motion else { return dissolve(previous, current, fraction: fraction) }
        let f = min(max(fraction, 0), 1)
        let a = previous.transformed(by: CGAffineTransform(translationX: motion.dx * f, y: motion.dy * f))
        let b = current.transformed(by: CGAffineTransform(translationX: -motion.dx * (1 - f), y: -motion.dy * (1 - f)))
        return dissolve(a, b, fraction: f)
    }

    private func dissolve(_ a: CIImage, _ b: CIImage, fraction: CGFloat) -> CIImage {
        let filter = CIFilter(name: "CIDissolveTransition")!
        filter.setValue(a, forKey: kCIInputImageKey); filter.setValue(b, forKey: kCIInputTargetImageKey)
        filter.setValue(min(max(fraction, 0), 1), forKey: kCIInputTimeKey)
        return filter.outputImage ?? b
    }

    private func normalizedImage(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let transformed = image.transformed(by: transform); let e = transformed.extent
        return transformed.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    private func append(_ image: CIImage, at time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, width: Int, height: Int) async throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? makeError("Video writer stopped") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw makeError("Pixel buffer pool unavailable") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw makeError("Unable to allocate video frame") }
        let e = image.extent; let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sx = CGFloat(width) / max(normalized.extent.width, 1); let sy = CGFloat(height) / max(normalized.extent.height, 1)
        let finalImage = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.render(finalImage, to: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private struct Frame { let pixelBuffer: CVPixelBuffer; let image: CIImage; let time: CMTime }
}

private final class OpticalFlowEngine {
    struct Motion { let dx: CGFloat; let dy: CGFloat }
    func estimate(from source: CVPixelBuffer, to target: CVPixelBuffer) throws -> Motion {
        guard CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(target), CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(target) else { throw NSError(domain: "FrameBoost.OpticalFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Optical-flow frames have different dimensions"]) }
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target, options: [:]); request.computationAccuracy = .medium; request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:]); try handler.perform([request])
        guard let observation = request.results?.first as? VNPixelBufferObservation else { return Motion(dx: 0, dy: 0) }
        let flow = observation.pixelBuffer; CVPixelBufferLockBaseAddress(flow, .readOnly); defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return Motion(dx: 0, dy: 0) }
        let fw = CVPixelBufferGetWidth(flow); let fh = CVPixelBufferGetHeight(flow); let rowStride = CVPixelBufferGetBytesPerRow(flow) / MemoryLayout<Float>.size
        let values = base.assumingMemoryBound(to: Float.self); var xs: [Float] = []; var ys: [Float] = []
        let stepX = max(fw / 16, 1); let stepY = max(fh / 16, 1)
        for y in Swift.stride(from: stepY / 2, to: fh, by: stepY) { for x in Swift.stride(from: stepX / 2, to: fw, by: stepX) { let index = y * rowStride + x * 2; let dx = values[index]; let dy = values[index + 1]; if dx.isFinite && dy.isFinite && abs(dx) < 256 && abs(dy) < 256 { xs.append(dx); ys.append(dy) } } }
        guard !xs.isEmpty else { return Motion(dx: 0, dy: 0) }
        xs.sort(); ys.sort(); let trim = xs.count / 10; let lo = trim; let hi = max(xs.count - trim, lo + 1)
        return Motion(dx: CGFloat(xs[lo..<hi].reduce(0, +) / Float(hi - lo)), dy: CGFloat(ys[lo..<hi].reduce(0, +) / Float(hi - lo)))
    }
}
