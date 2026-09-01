import Foundation

struct FrameBoostSettings: Equatable {
    var multiplier: Int = 2
    var quality: Double = 0.85
    var preserveAudio: Bool = true
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
        guard let input = selectedVideoURL else { return }
        isProcessing = true
        errorMessage = nil
        outputURL = await processor.process(inputURL: input, multiplier: settings.multiplier)
        progress = processor.progress
        isProcessing = false
        if outputURL == nil { errorMessage = processor.errorMessage }
    }

    func cancel() { processor.cancel() }
}
