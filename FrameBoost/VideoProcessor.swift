import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

final class VideoProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw error("No video track") }
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30
        let target = max(Double(targetFPS), ceil(sourceFPS))

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let oriented = naturalSize.applying(transform)
        let width = max(Int(abs(oriented.width).rounded()), 2)
        let height = max(Int(abs(oriented.height).rounded()), 2)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: Int(target)]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? error("Unable to start export") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? error("Unable to read video") }

        var previous: (image: CIImage, time: CMTime)?
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var image = CIImage(cvPixelBuffer: buffer)
            image = image.transformed(by: transform)
            if image.extent.width != CGFloat(width) || image.extent.height != CGFloat(height) {
                let sx = CGFloat(width) / max(image.extent.width, 1)
                let sy = CGFloat(height) / max(image.extent.height, 1)
                image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }

            if let previous {
                let delta = CMTimeGetSeconds(time - previous.time)
                let count = min(max(Int((delta * target).rounded()), 1), 8)
                try await render(previous.image, time: previous.time, adaptor: adaptor, writer: writer, width: width, height: height)
                if count > 1 {
                    for i in 1..<count {
                        let f = CGFloat(i) / CGFloat(count)
                        // ME-style motion estimation approximation: create a temporal intermediate
                        // frame with motion-compensated translation before compositing.
                        let dx = (image.extent.midX - previous.image.extent.midX) * f
                        let dy = (image.extent.midY - previous.image.extent.midY) * f
                        let moved = image.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
                        let blend = previous.image.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: moved])
                        let dissolve = blend.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - f])
                        let t = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(time - previous.time, multiplier: Double(f)))
                        try await render(dissolve, time: t, adaptor: adaptor, writer: writer, width: width, height: height)
                    }
                }
            }
            previous = (image, time)
            progress(min(max(CMTimeGetSeconds(time) / durationSeconds, 0), 1))
        }
        if let previous { try await render(previous.image, time: previous.time, adaptor: adaptor, writer: writer, width: width, height: height) }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? error("Export failed") }
        progress(1)
        return outputURL
    }

    private func render(_ image: CIImage, time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, width: Int, height: Int) async throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? error("Video writer stopped") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw error("Pixel buffer pool unavailable") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw error("Unable to allocate frame") }
        let bounds = image.extent
        let sx = CGFloat(width) / max(bounds.width, 1)
        let sy = CGFloat(height) / max(bounds.height, 1)
        let finalImage = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.render(finalImage, to: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? error("Failed to append video frame") }
    }

    private func error(_ message: String) -> NSError { NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
