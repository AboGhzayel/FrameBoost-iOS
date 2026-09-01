import Foundation
import Combine
import AVFoundation

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
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw NSError(domain: "FrameBoost", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
                }
                let nominal = try await track.load(.nominalFrameRate)
                let sourceFPS = max(Int(nominal.rounded()), 1)

                var options = VideoProcessingOptions(targetFPS: requestedFPS)
                switch profile {
                case .tiktokPro:
                    options.exportWidth = 1080
                    options.exportHeight = 1920
                    options.bitrate = sourceFPS >= 60 ? 14_000_000 : 12_000_000
                    options.forceSDR = true
                case .smoothSlowmo:
                    options.bitrate = 18_000_000
                case .fastRender:
                    options.bitrate = 10_000_000
                case .extremeCar:
                    options.bitrate = 14_000_000
                case .smooth60:
                    options.bitrate = 12_000_000
                }

                let result = try await processor.process(url: input, options: options) { [weak self] value in
                    Task { @MainActor in
                        self?.progress = value
                    }
                }
                try Task.checkCancellation()
                self.outputURL = result
                self.progress = 1
                self.isProcessing = false
                self.processingTask = nil
            } catch is CancellationError {
                self.isProcessing = false
                self.processingTask = nil
                self.errorMessage = "Processing cancelled."
            } catch {
                self.isProcessing = false
                self.processingTask = nil
                self.errorMessage = "Export failed: \(error.localizedDescription)"
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
