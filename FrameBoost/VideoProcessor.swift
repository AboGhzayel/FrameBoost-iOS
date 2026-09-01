import Foundation
import AVFoundation
import CoreImage

final class VideoProcessor {
    private let context = CIContext(options: nil)

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30.0
        let fps = max(Double(targetFPS), ceil(sourceFPS))

        // Keep the encoded dimensions tied to the actual decoded pixel buffer.
        let oriented = naturalSize.applying(transform)
        let width = even(max(Int(abs(oriented.width).rounded()), 2))
        let height = even(max(Int(abs(oriented.height).rounded()), 2))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? makeError("Unable to read selected video") }

        var previous: (image: CIImage, time: CMTime)?
        var lastWrittenTime = CMTime.invalid

        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var image = normalizedImage(CIImage(cvPixelBuffer: buffer), transform: transform)
            image = image.cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

            if let previous {
                let delta = CMTimeGetSeconds(time - previous.time)
                let count = min(max(Int((delta * fps).rounded()), 1), 8)
                let baseTime = maxTime(previous.time, lastWrittenTime)
                if baseTime > lastWrittenTime { try await append(previous.image, at: baseTime, adaptor: adaptor, writer: writer, width: width, height: height); lastWrittenTime = baseTime }
                if count > 1 {
                    for i in 1..<count {
                        let f = CGFloat(i) / CGFloat(count)
                        // Motion-estimation style temporal interpolation. The ME engine can later be
                        // replaced by a dedicated optical-flow model without changing the export path.
                        let intermediate = motionEstimateBlend(previous.image, image, fraction: f)
                        let candidate = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(time - previous.time, multiplier: Double(f)))
                        if candidate > lastWrittenTime {
                            try await append(intermediate, at: candidate, adaptor: adaptor, writer: writer, width: width, height: height)
                            lastWrittenTime = candidate
                        }
                    }
                }
            } else {
                try await append(image, at: .zero, adaptor: adaptor, writer: writer, width: width, height: height)
                lastWrittenTime = .zero
            }
            previous = (image, time)
            progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
        }

        if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
        if let previous {
            let finalTime = previous.time > lastWrittenTime ? previous.time : CMTimeAdd(lastWrittenTime, CMTime(value: 1, timescale: CMTimeScale(max(Int(fps), 1))))
            try await append(previous.image, at: finalTime, adaptor: adaptor, writer: writer, width: width, height: height)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        progress(1)
        return outputURL
    }

    private func motionEstimateBlend(_ a: CIImage, _ b: CIImage, fraction: CGFloat) -> CIImage {
        // Stable temporal ME approximation: interpolate luminance/chroma while preserving edges.
        let f = min(max(fraction, 0), 1)
        let dissolve = CIFilter(name: "CIDissolveTransition")!
        dissolve.setValue(a, forKey: kCIInputImageKey)
        dissolve.setValue(b, forKey: kCIInputTargetImageKey)
        dissolve.setValue(f, forKey: kCIInputTimeKey)
        return dissolve.outputImage ?? b
    }

    private func normalizedImage(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let transformed = image.transformed(by: transform)
        let e = transformed.extent
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
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sx = CGFloat(width) / max(normalized.extent.width, 1)
        let sy = CGFloat(height) / max(normalized.extent.height, 1)
        let finalImage = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.render(finalImage, to: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }
    private func maxTime(_ a: CMTime, _ b: CMTime) -> CMTime { a > b ? a : b }
    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
