import Foundation
import Combine

struct FrameBoostSettings: Equatable {
    var targetFPS: Int = 60
    var preserveAudio: Bool = true
    var quality: Double = 0.92
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

    private let processor = VideoProcessor()
    private var processingTask: Task<Void, Never>?

    func startProcessing() {
        guard let input = selectedVideoURL, !isProcessing else { return }
        isProcessing = true
        progress = 0
        errorMessage = nil
        outputURL = nil
        let profile = selectedProfile
        let requestedFPS = profile.targetFPS
        settings.targetFPS = requestedFPS

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVAsset(url: input)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "FrameBoost", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track found"]) }
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let oriented = natural.applying(transform)
                let sourceW = max(Int(abs(oriented.width).rounded()), 2)
                let sourceH = max(Int(abs(oriented.height).rounded()), 2)
                let sourceFPS = max(Int((try await track.load(.nominalFrameRate)).rounded()), 1)

                var options = VideoProcessingOptions(targetFPS: requestedFPS)
                if profile == .tiktokPro {
                    options.exportWidth = 1080
                    options.exportHeight = 1920
                    options.bitrate = 12_000_000
                    options.forceSDR = true
                } else if profile == .smoothSlowmo {
                    options.bitrate = 18_000_000
                } else if profile == .fastRender {
                    options.bitrate = 10_000_000
                } else if profile == .extremeCar {
                    options.bitrate = 14_000_000
                } else {
                    options.bitrate = 12_000_000
                }

                // Keep source dimensions available for future platform-aware transforms.
                _ = (sourceW, sourceH, sourceFPS)
                let result = try await processor.process(url: input, options: options) { value in
                    Task { @MainActor [weak self] in self?.progress = value }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self.outputURL = result
                    self.progress = 1
                    self.isProcessing = false
                    self.processingTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                    self.processingTask = nil
                    self.errorMessage = "Processing cancelled."
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.processingTask = nil
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func process() async { startProcessing() }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        errorMessage = "Processing cancelled."
    }
}
