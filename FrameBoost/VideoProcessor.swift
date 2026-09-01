import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

final class VideoProcessor {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "FrameBoost", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let duration = try await asset.load(.duration)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let sourceFPS = nominalFPS > 0 ? nominalFPS : 30
        let target = max(targetFPS, Int(ceil(sourceFPS)))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let size = try await videoTrack.load(.naturalSize)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "FrameBoost", code: 2) }

        var previous: (buffer: CVPixelBuffer, time: CMTime)?
        while let sample = output.copyNextSampleBuffer() {
            guard let currentBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
            if let previous {
                let delta = CMTimeGetSeconds(CMTimeSubtract(currentTime, previous.time))
                if delta > 0 && delta < 1 {
                    let steps = min(max(Int((delta * Double(target)).rounded()), 1), 8)
                    try await appendFrame(previous.buffer, at: previous.time, to: adaptor)
                    if steps > 1 {
                        for index in 1..<steps {
                            let fraction = CGFloat(index) / CGFloat(steps)
                            let intermediateTime = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(CMTimeSubtract(currentTime, previous.time), multiplier: Float64(fraction)))
                            try await appendBlend(from: previous.buffer, to: currentBuffer, fraction: fraction, at: intermediateTime, to: adaptor)
                        }
                    }
                }
            } else {
                try await appendFrame(currentBuffer, at: .zero, to: adaptor)
            }
            previous = (currentBuffer, currentTime)
            progress(min(max(CMTimeGetSeconds(currentTime) / max(CMTimeGetSeconds(duration), 0.001), 0), 1))
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "FrameBoost", code: 3) }
        if let previous { try await appendFrame(previous.buffer, at: previous.time, to: adaptor) }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "FrameBoost", code: 4) }
        _ = frameDuration
        progress(1)
        return outputURL
    }

    private func appendFrame(_ buffer: CVPixelBuffer, at time: CMTime, to adaptor: AVAssetWriterInputPixelBufferAdaptor) async throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw NSError(domain: "FrameBoost", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to append video frame"])
        }
    }

    private func appendBlend(from first: CVPixelBuffer, to second: CVPixelBuffer, fraction: CGFloat, at time: CMTime, to adaptor: AVAssetWriterInputPixelBufferAdaptor) async throws {
        guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "FrameBoost", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate output frame"] ) }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer else { throw NSError(domain: "FrameBoost", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate output frame"] ) }
        let firstImage = CIImage(cvPixelBuffer: first)
        let secondImage = CIImage(cvPixelBuffer: second)
        let filter = CIFilter(name: "CIDissolveTransition")!
        filter.setValue(firstImage, forKey: kCIInputImageKey)
        filter.setValue(secondImage, forKey: kCIInputTargetImageKey)
        filter.setValue(fraction, forKey: kCIInputTimeKey)
        guard let image = filter.outputImage else { throw NSError(domain: "FrameBoost", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to create interpolated frame"] ) }
        ciContext.render(image, to: outputBuffer)
        while !adaptor.assetWriterInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        guard adaptor.append(outputBuffer, withPresentationTime: time) else {
            throw NSError(domain: "FrameBoost", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to append interpolated frame"])
        }
    }
}
