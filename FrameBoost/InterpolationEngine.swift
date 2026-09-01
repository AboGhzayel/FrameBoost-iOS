import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Frame interpolation pipeline abstraction.
/// The current implementation provides a safe AVFoundation export path.
/// A motion-compensated/ML interpolator can be plugged into this protocol later.
protocol FrameInterpolationEngine {
    func interpolate(input: URL, multiplier: Int, output: URL) async throws
}

struct AVFoundationInterpolationEngine: FrameInterpolationEngine {
    func interpolate(input: URL, multiplier: Int, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "FrameBoost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create export session."])
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "FrameBoost", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed."])
        }
        _ = multiplier
    }
}
