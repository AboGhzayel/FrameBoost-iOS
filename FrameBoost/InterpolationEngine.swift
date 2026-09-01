import AVFoundation
import Foundation

/// Stable interpolation-engine contract. VideoProcessor owns frame generation
/// and this type provides a clean seam for a future ML/optical-flow backend.
protocol FrameInterpolationEngine {
    func interpolate(input: URL, multiplier: Int, output: URL) async throws
}

/// Pass-through export engine retained for compatibility with the project.
/// It deliberately does not perform a second export while VideoProcessor is
/// processing frames, avoiding duplicate AVAssetWriter/ExportSession pipelines.
struct AVFoundationInterpolationEngine: FrameInterpolationEngine {
    func interpolate(input: URL, multiplier: Int, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
        _ = multiplier
    }
}
