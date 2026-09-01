import Foundation
import AVFoundation
import CoreML

/// AI-ready interpolation backend.
/// The bundled app remains fully functional without a model. When a compatible
/// Core ML frame-interpolation model is added as `FrameInterpolation.mlmodelc`,
/// this engine can be selected by the processor without changing the export API.
final class AIInterpolationEngine {
    private let modelURL: URL?

    init() {
        modelURL = Bundle.main.url(forResource: "FrameInterpolation", withExtension: "mlmodelc")
    }

    var isAvailable: Bool { modelURL != nil }

    func makeConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return configuration
    }

    func statusText() -> String {
        isAvailable ? "AI interpolation ready" : "AI model not installed — using safe fallback"
    }
}
