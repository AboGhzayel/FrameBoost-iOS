import Foundation
import CoreML
import CoreVideo

/// 60 FPS-only frame-generation contract for FrameBoost.
/// RIFE 4.25 is the selected open-source model target; until its Core ML
/// conversion is bundled, the app must not claim that fallback frames are AI.
struct AIFrameGenerationPlan: Sendable {
    let inputFPS: Double
    let outputFPS: Double
    let factor: Int
    let modelName: String

    var needsGeneration: Bool { inputFPS < 59.5 }

    static func for60FPS(input: Double) -> Self {
        let safeInput = max(input, 1)
        return Self(
            inputFPS: safeInput,
            outputFPS: 60,
            factor: max(Int((60.0 / safeInput).rounded()), 1),
            modelName: "RIFE-4.25"
        )
    }
}

final class AIFrameGenerator {
    private let model: MLModel?

    init() {
        // Expected converted Core ML artifact. It is intentionally optional
        // until the exact RIFE 4.25 feature schema is converted and validated.
        guard let url = Bundle.main.url(forResource: "RIFE_4_25", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration())
    }

    var isAvailable: Bool { model != nil }

    func generateIntermediateFrame(input0: CVPixelBuffer, input1: CVPixelBuffer, timestep: Float) throws -> CVPixelBuffer? {
        // Do not guess the model's tensor schema. Once the converted model is
        // bundled, this adapter will map its exact inputs/outputs here.
        guard model != nil else { return nil }
        return nil
    }
}
