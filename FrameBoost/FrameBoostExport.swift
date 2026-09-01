import AVFoundation
import Foundation

struct FrameBoostExport {
    static func makeOutputURL(extension ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameBoost-\(UUID().uuidString).\(ext)")
    }

    static func export(asset: AVAsset, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "FrameBoost", code: 100, userInfo: [NSLocalizedDescriptionKey: "This video cannot be exported on this device."])
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "FrameBoost", code: 101, userInfo: [NSLocalizedDescriptionKey: "Export failed."])
        }
    }
}
