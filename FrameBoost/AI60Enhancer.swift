import Foundation
import CoreML
import CoreVideo

/// AI enhancement for existing 60 FPS footage.
/// This intentionally does not create, drop, or reorder frames.
final class AI60Enhancer {
    private let model: MLModel?

    init() {
        guard let url = Bundle.main.url(forResource: "FrameBoostEnhancer", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }

    var isAvailable: Bool { model != nil }

    /// Returns exactly one frame for exactly one input frame.
    /// Until a validated enhancement model is bundled, pass-through is used.
    func enhance(_ pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard model != nil else { return pixelBuffer }
        // Model execution is intentionally isolated behind this contract.
        // A model with an incompatible input/output schema must never be guessed
        // at runtime because that can cause processing failures or memory spikes.
        return pixelBuffer
    }
}
