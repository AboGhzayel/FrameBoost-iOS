import AVFoundation
import Foundation

@MainActor
final class VideoProcessor: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isProcessing = false
    @Published private(set) var errorMessage: String?

    private var exportSession: AVAssetExportSession?

    func process(inputURL: URL, multiplier: Int) async -> URL? {
        guard !isProcessing else { return nil }
        isProcessing = true
        progress = 0
        errorMessage = nil
        defer { isProcessing = false; exportSession = nil }

        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            errorMessage = "Unable to read the video."
            return nil
        }

        let duration = (try? await asset.load(.duration)) ?? .zero
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameBoost-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Phase 1: reliable transcode/export pipeline.
        // True optical-flow interpolation will replace this stage in the next engine version.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            errorMessage = "Video export is not supported on this device."
            return nil
        }
        exportSession = session
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let progressTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let session else { break }
                await MainActor.run { self?.progress = Double(session.progress) }
                if session.status != .exporting { break }
            }
        }

        await session.export()
        progressTask.cancel()
        progress = 1

        guard session.status == .completed else {
            errorMessage = session.error?.localizedDescription ?? "Export failed."
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        // Keep multiplier in the API now so the interpolation engine can be swapped in without changing UI.
        _ = multiplier
        _ = videoTrack
        _ = duration
        return outputURL
    }

    func cancel() {
        exportSession?.cancelExport()
    }
}
