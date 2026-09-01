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

    func process() async {
        guard let input = selectedVideoURL, !isProcessing else { return }
        isProcessing = true
        progress = 0
        errorMessage = nil
        outputURL = nil

        let result = await processor.process(
            inputURL: input,
            targetFPS: settings.targetFPS,
            preserveAudio: settings.preserveAudio
        ) { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }

        if Task.isCancelled { return }
        outputURL = result
        progress = result == nil ? progress : 1
        errorMessage = result == nil ? processor.errorMessage : nil
        isProcessing = false
    }

    func cancel() {
        processor.cancel()
        isProcessing = false
    }
}
