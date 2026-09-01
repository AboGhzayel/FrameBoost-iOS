import AVFoundation
import CoreImage
import CoreVideo
import Foundation

@MainActor
final class VideoProcessor: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isProcessing = false
    @Published private(set) var errorMessage: String?

    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    func process(inputURL: URL, targetFPS: Int, preserveAudio: Bool, progressHandler: @escaping (Double) -> Void) async -> URL? {
        guard !isProcessing else { return nil }
        isProcessing = true
        cancelled = false
        progress = 0
        errorMessage = nil
        defer {
            isProcessing = false
            reader = nil
            writer = nil
        }

        do {
            let asset = AVURLAsset(url: inputURL)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw ProcessorError.message("No video track was found.")
            }

            let duration = try await asset.load(.duration)
            let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: outputURL)

            try await renderVideo(
                asset: asset,
                videoTrack: videoTrack,
                outputURL: outputURL,
                targetFPS: targetFPS,
                durationSeconds: durationSeconds,
                naturalSize: naturalSize,
                transform: transform,
                progressHandler: progressHandler
            )

            if cancelled {
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard preserveAudio, !audioTracks.isEmpty else {
                progress = 1
                progressHandler(1)
                return outputURL
            }

            let finalURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FrameBoost-TikTok-\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: finalURL)
            try await muxOriginalAudio(videoURL: outputURL, sourceAsset: asset, outputURL: finalURL)
            try? FileManager.default.removeItem(at: outputURL)
            progress = 1
            progressHandler(1)
            return finalURL
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        cancelled = true
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private func renderVideo(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        outputURL: URL,
        targetFPS: Int,
        durationSeconds: Double,
        naturalSize: CGSize,
        transform: CGAffineTransform,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw ProcessorError.message("Unable to read video frames.") }
        reader.add(trackOutput)
        self.reader = reader

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let transformedSize = naturalSize.applying(transform)
        let outputWidth = max(Int(abs(transformedSize.width)), 2)
        let outputHeight = max(Int(abs(transformedSize.height)), 2)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, outputWidth * outputHeight * 8),
                AVVideoExpectedSourceFrameRateKey: targetFPS,
                AVVideoMaxKeyFrameIntervalKey: targetFPS * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = .identity
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(writerInput) else { throw ProcessorError.message("Unable to create video output.") }
        writer.add(writerInput)
        self.writer = writer

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? ProcessorError.message("Unable to start video processing.")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: nil)
        var previous: (buffer: CVPixelBuffer, time: CMTime)?
        let targetFrameSeconds = 1.0 / Double(max(targetFPS, 1))
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        while let sample = trackOutput.copyNextSampleBuffer() {
            if cancelled { throw CancellationError() }
            guard let currentBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)

            if let previous {
                let delta = CMTimeGetSeconds(CMTimeSubtract(currentTime, previous.time))
                if delta > 0, delta < 1 {
                    let steps = min(max(Int((delta / targetFrameSeconds).rounded()), 1), 8)
                    try appendFrame(previous.buffer, at: previous.time, to: adaptor, context: context, outputSize: outputSize)

                    if steps > 1 {
                        for index in 1..<steps {
                            let fraction = CGFloat(index) / CGFloat(steps)
                            let intermediateTime = CMTimeAdd(
                                previous.time,
                                CMTimeMultiplyByFloat64(CMTimeSubtract(currentTime, previous.time), Float64(fraction))
                            )
                            try appendBlend(
                                from: previous.buffer,
                                to: currentBuffer,
                                fraction: fraction,
                                at: intermediateTime,
                                to: adaptor,
                                context: context,
                                outputSize: outputSize
                            )
                        }
                    }
                }
            }
            previous = (currentBuffer, currentTime)

            let value = min(max(CMTimeGetSeconds(currentTime) / durationSeconds, 0), 0.99)
            progress = value
            progressHandler(value)
        }

        if let previous {
            try appendFrame(previous.buffer, at: previous.time, to: adaptor, context: context, outputSize: outputSize)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ProcessorError.message("Video encoding failed.")
        }
    }

    private func appendFrame(
        _ buffer: CVPixelBuffer,
        at time: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        context: CIContext,
        outputSize: CGSize
    ) throws {
        guard let pool = adaptor.pixelBufferPool else { throw ProcessorError.message("Unable to allocate output frames.") }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { throw ProcessorError.message("Unable to allocate output frame.") }
        let image = fittedImage(CIImage(cvPixelBuffer: buffer), outputSize: outputSize)
        context.render(image, to: output)
        guard adaptor.append(output, withPresentationTime: time) else {
            throw ProcessorError.message("Unable to write video frame.")
        }
    }

    private func appendBlend(
        from first: CVPixelBuffer,
        to second: CVPixelBuffer,
        fraction: CGFloat,
        at time: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        context: CIContext,
        outputSize: CGSize
    ) throws {
        guard let pool = adaptor.pixelBufferPool else { throw ProcessorError.message("Unable to allocate output frames.") }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { throw ProcessorError.message("Unable to allocate output frame.") }

        let firstImage = fittedImage(CIImage(cvPixelBuffer: first), outputSize: outputSize)
        let secondImage = fittedImage(CIImage(cvPixelBuffer: second), outputSize: outputSize)
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: fraction))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
        let filter = CIFilter(name: "CIBlendWithAlphaMask")!
        filter.setValue(firstImage, forKey: kCIInputImageKey)
        filter.setValue(secondImage, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let result = filter.outputImage else { throw ProcessorError.message("Unable to interpolate frames.") }
        context.render(result, to: output)
        guard adaptor.append(output, withPresentationTime: time) else {
            throw ProcessorError.message("Unable to write interpolated frame.")
        }
    }

    private func fittedImage(_ image: CIImage, outputSize: CGSize) -> CIImage {
        let scale = max(outputSize.width / image.extent.width, outputSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (scaled.extent.width - outputSize.width) / 2
        let y = (scaled.extent.height - outputSize.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX - x, y: -scaled.extent.minY - y))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private func muxOriginalAudio(videoURL: URL, sourceAsset: AVAsset, outputURL: URL) async throws {
        let processedAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await processedAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard let processedVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
            throw ProcessorError.message("Unable to prepare audio.")
        }

        let composition = AVMutableComposition()
        guard let destinationVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let destinationAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessorError.message("Unable to prepare final video.")
        }
        let processedDuration = try await processedAsset.load(.duration)
        let audioDuration = try await sourceAsset.load(.duration)
        try destinationVideo.insertTimeRange(CMTimeRange(start: .zero, duration: processedDuration), of: processedVideo, at: .zero)
        try destinationAudio.insertTimeRange(CMTimeRange(start: .zero, duration: min(processedDuration, audioDuration)), of: sourceAudio, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessorError.message("Unable to finalize video.")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? ProcessorError.message("Unable to finalize audio.")
        }
    }
}

enum ProcessorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
