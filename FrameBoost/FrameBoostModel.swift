import Foundation
import Combine
import AVFoundation
import CoreImage

struct FrameBoostSettings: Equatable { var targetFPS: Int = 60; var preserveAudio: Bool = true; var quality: Double = 0.92 }

enum ProcessingMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case onDevice = "On Device"
    var id: String { rawValue }
    var subtitle: String { switch self { case .auto: return "Automatic on-device processing"; case .onDevice: return "Private • works offline • RIFE 4.25" } }
}

@MainActor
final class FrameBoostModel: ObservableObject {
    @Published var settings = FrameBoostSettings()
    @Published var selectedVideoURL: URL?
    @Published var outputURL: URL?
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var selectedProfile: ProcessingProfile = .tiktokPro
    @Published var processingMode: ProcessingMode = .auto
    @Published var cloudStatus: String?
    @Published var preprocessingProfile: PreprocessingProfile = .turbo

    private let processor = VideoProcessor()
    private let preprocessor = VideoPreprocessor()
    private var processingTask: Task<Void, Never>?

    func startProcessing() {
        guard let input = selectedVideoURL, !isProcessing else { return }
        isProcessing = true; progress = 0; errorMessage = nil; cloudStatus = nil; outputURL = nil
        let profile = selectedProfile
        settings.targetFPS = profile.targetFPS
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVAsset(url: input)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "FrameBoost", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track found"]) }
                let nominal = try await track.load(.nominalFrameRate)
                let sourceFPS = max(Int(nominal.rounded()), 1)
                var options = VideoProcessingOptions(targetFPS: profile.targetFPS)
                switch profile {
                case .tiktokPro: options.exportWidth = 1080; options.exportHeight = 1920; options.bitrate = sourceFPS >= 60 ? 14_000_000 : 12_000_000; options.colorMode = .automatic
                case .smoothSlowmo: options.bitrate = 18_000_000
                case .fastRender: options.bitrate = 10_000_000
                case .extremeCar: options.bitrate = 14_000_000; options.motionBlur = true; options.motionBlurStrength = 0.55
                case .smooth60: options.bitrate = 12_000_000
                }
                // Auto is intentionally on-device only. No network/GPU server is required.
                let sourceForAI = input
                if preprocessingProfile != .turbo {
                    cloudStatus = "Preparing on device…"
                    let prepared = try await preprocessor.reencode(url: input, profile: preprocessingProfile) { [weak self] value in
                        Task { @MainActor in self?.progress = value * 0.20; self?.cloudStatus = "Preparing • \(Int(value * 100))%" }
                    }
                    outputURL = try await processor.process(url: prepared, options: options) { [weak self] value in Task { @MainActor in self?.progress = 0.20 + value * 0.80 } }
                    try? FileManager.default.removeItem(at: prepared)
                } else {
                    outputURL = try await processor.process(url: sourceForAI, options: options) { [weak self] value in Task { @MainActor in self?.progress = value } }
                }
                try Task.checkCancellation(); progress = 1; isProcessing = false; processingTask = nil; cloudStatus = nil
            } catch is CancellationError { isProcessing = false; processingTask = nil; errorMessage = "Processing cancelled."; cloudStatus = nil }
            catch { isProcessing = false; processingTask = nil; errorMessage = "Export failed: \(error.localizedDescription)"; cloudStatus = nil }
        }
    }
    func process() async { startProcessing() }
    func cancel() { processingTask?.cancel(); processingTask = nil; isProcessing = false; errorMessage = "Processing cancelled."; cloudStatus = nil }
}

final class VideoPreprocessor: @unchecked Sendable {
    private let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    func reencode(url: URL, profile: PreprocessingProfile, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "FrameBoost.Preprocessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track"]) }
        let duration = max(CMTimeGetSeconds(try await asset.load(.duration)), 0.001)
        let sourceFPS = max(Double(try await track.load(.nominalFrameRate)), 1)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let rawWidth = max(Int(abs(size.width.rounded())), 2); let rawHeight = max(Int(abs(size.height.rounded())), 2)
        let width = rawWidth % 2 == 0 ? rawWidth : rawWidth - 1; let height = rawHeight % 2 == 0 ? rawHeight : rawHeight - 1
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoost-Preprocessed-\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]); ro.alwaysCopiesSampleData = false; reader.add(ro)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4); let fps = max(Int(sourceFPS.rounded()), 1)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: profile.bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA, String(kCVPixelBufferWidthKey): width, String(kCVPixelBufferHeightKey): height])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? NSError(domain: "FrameBoost.Preprocessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to start preprocessing"]) }; writer.startSession(atSourceTime: .zero); guard reader.startReading() else { throw reader.error ?? NSError(domain: "FrameBoost.Preprocessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to read source"]) }
        while let sample = ro.copyNextSampleBuffer() {
            try Task.checkCancellation(); guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }; let time = CMSampleBufferGetPresentationTimeStamp(sample); var image = CIImage(cvPixelBuffer: buffer)
            if profile == .motionBlur { image = image.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: CGFloat(profile.blurStrength), kCIInputAngleKey: 0.0]) }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }; guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "FrameBoost.Preprocessor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Pixel buffer pool unavailable"]) }; var out: CVPixelBuffer?; guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { throw NSError(domain: "FrameBoost.Preprocessor", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate preprocessing frame"]) }
            let e = image.extent.integral; let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)); let sx = CGFloat(width) / max(e.width, 1); let sy = CGFloat(height) / max(e.height, 1); let final = normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))); context.render(final, to: out); guard adaptor.append(out, withPresentationTime: time) else { throw writer.error ?? NSError(domain: "FrameBoost.Preprocessor", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to append preprocessing frame"]) }; progress(min(max(CMTimeGetSeconds(time) / duration, 0), 1))
        }
        input.markAsFinished(); await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? NSError(domain: "FrameBoost.Preprocessor", code: -7, userInfo: [NSLocalizedDescriptionKey: "Preprocessing export failed"]) }; progress(1); return output
    }
}
