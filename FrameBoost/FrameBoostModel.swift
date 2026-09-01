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

    func process() async {
        guard let input = selectedVideoURL, !isProcessing else { return }
        let targetFPS = settings.targetFPS
        isProcessing = true
        progress = 0
        errorMessage = nil
        outputURL = nil

        do {
            let result = try await processor.process(url: input, targetFPS: targetFPS) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            guard !Task.isCancelled else { throw CancellationError() }
            outputURL = result
            progress = 1
        } catch is CancellationError {
            errorMessage = "Processing cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }

    func startProcessing() {
        guard processingTask == nil, selectedVideoURL != nil else { return }
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process()
            self.processingTask = nil
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        errorMessage = "Processing cancelled."
    }
}
