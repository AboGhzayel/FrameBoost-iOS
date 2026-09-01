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

    private let processor = VideoProcessor()
    private var processingTask: Task<Void, Never>?

    func startProcessing() {
        guard let input = selectedVideoURL, !isProcessing else { return }
        isProcessing = true
        progress = 0
        errorMessage = nil
        outputURL = nil
        let fps = settings.targetFPS
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await processor.process(url: input, targetFPS: fps) { value in
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
