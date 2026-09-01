import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

final class VideoProcessor {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func process(url: URL, targetFPS: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw makeError("No video track") }
        let duration = try await asset.load(.duration)
        let nominal = try await track.load(.nominalFrameRate)
        let sourceFPS = nominal > 0 ? Double(nominal) : 30.0
        let target = max(Double(targetFPS), ceil(sourceFPS))
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let naturalSize = try await track.load(.naturalSize)
        let width = max(Int(naturalSize.width), 2)
        let height = max(Int(naturalSize.height), 2)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(writerInput)
        guard writer.startWriting() else { throw writer.error ?? makeError("Unable to start video writer") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? makeError("Unable to read video") }

        var previous: (buffer: CVPixelBuffer, time: CMTime)?
        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let current = CMSampleBufferGetImageBuffer(sample) else { continue }
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)

            if let previous {
                let delta = CMTimeGetSeconds(CMTimeSubtract(currentTime, previous.time))
                if delta > 0.0001 && delta < 1.0 {
                    let count = min(max(Int((delta * target).rounded()), 1), 8)
                    try await append(buffer: previous.buffer, time: previous.time, adaptor: adaptor, writer: writer)
                    if count > 1 {
                        for index in 1..<count {
                            let fraction = CGFloat(index) / CGFloat(count)
                            let intermediateTime = CMTimeAdd(previous.time, CMTimeMultiplyByFloat64(CMTimeSubtract(currentTime, previous.time), multiplier: Float64(fraction)))
                            try await appendBlend(first: previous.buffer, second: current, fraction: fraction, time: intermediateTime, adaptor: adaptor, writer: writer)
                        }
                    }
                }
            } else {
                try await append(buffer: current, time: .zero, adaptor: adaptor, writer: writer)
            }
            previous = (current, currentTime)
            progress(min(max(CMTimeGetSeconds(currentTime) / durationSeconds, 0), 1))
        }

        if reader.status == .failed { throw reader.error ?? makeError("Video reader failed") }
        if let previous { try await append(buffer: previous.buffer, time: previous.time, adaptor: adaptor, writer: writer) }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? makeError("Video export failed") }
        progress(1)
        return outputURL
    }

    private func append(buffer: CVPixelBuffer, time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter) async throws {
        while !adaptor.assetWriterInput.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? makeError("Video writer stopped") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? makeError("Failed to append video frame") }
    }

    private func appendBlend(first: CVPixelBuffer, second: CVPixelBuffer, fraction: CGFloat, time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter) async throws {
        guard let pool = adaptor.pixelBufferPool else { throw makeError("Unable to allocate output frame") }
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess, let outputBuffer else { throw makeError("Unable to allocate output frame") }

        let firstImage = CIImage(cvPixelBuffer: first)
        let secondImage = CIImage(cvPixelBuffer: second)
        let image = secondImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.0])
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: firstImage, kCIInputTimeKey: 1.0 - fraction])
        ciContext.render(image, to: outputBuffer)
        try await append(buffer: outputBuffer, time: time, adaptor: adaptor, writer: writer)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "FrameBoost", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
