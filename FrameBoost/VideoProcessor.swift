import Foundation
import AVFoundation
import CoreImage

final class VideoProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30.0
        let outputFPS = max(Double(targetFPS), ceil(sourceFPS))

        let oriented = naturalSize.applying(transform)
        let width = max(Int(abs(oriented.width).rounded()) & ~1, 2)
        let height = max(Int(abs(oriented.height).rounded()) & ~1, 2)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            let e = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            let sx = CGFloat(width) / max(image.extent.width, 1)
            let sy = CGFloat(height) / max(image.extent.height, 1)
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

            if let previous {
                let delta = CMTimeGetSeconds(time - previous.time)
                let count = min(max(Int((delta * outputFPS).rounded()), 1), 8)
                try await append(previous.image, at: previous.time, adaptor: adaptor, writer: writer, width: width, height: height)
                if count > 1 {
                    for i in 1..<count {
                        let f = CGFloat(i) / CGFloat(count)
                        let filter = CIFilter(name: "CIDissolveTransition")!
                        filter.setValue(previous.image, forKey: kCIInputImageKey)
                        filter.setValue(image, forKey: kCIInputTargetImageKey)
                        filter.setValue(f, forKey: kCIInputTimeKey)
                        guard let intermediate = filter.outputImage else { throw makeError("Unable to create interpolated frame") }
                        let t = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(time - previous.time, multiplier: Double(f)))
                        try await append(intermediate, at: t, adaptor: adaptor, writer: writer, width: width, height: height)
                    }
                }
            } else {
                try await append(image, at: .zero, adaptor: adaptor, writer: writer, width: width, height: height)
            }
            previous = (image, time)
            progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
        }

        if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
        if let previous { try await append(previous.image, at: previous.time, adaptor: adaptor, writer: writer, width: width, height: height) }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        progress(1)
        return outputURL
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

    private func makeError(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
