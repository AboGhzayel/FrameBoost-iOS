import Foundation
import CoreML

/// Describes the real Core ML frame-generation contract expected by FrameBoost.
/// No fake interpolation is reported as AI: until a compatible model is bundled,
/// callers must use the optical-flow fallback.
struct AIFrameGenerationPlan: Sendable {
    let inputFPS: Double
    let outputFPS: Double
    let factor: Int
    let modelName: String

    var canGenerate: Bool { factor >= 2 && outputFPS > inputFPS }

    static func forFPS(input: Double, output: Int) -> Self {
        let safeInput = max(input, 1)
        let safeOutput = max(Double(output), safeInput)
        let factor = max(Int((safeOutput / safeInput).rounded()), 1)
        return Self(inputFPS: safeInput, outputFPS: safeOutput, factor: factor, modelName: "FrameInterpolation")
    }
}

final class AIFrameGenerator {
    private let model: MLModel?

    init() {
        guard let url = Bundle.main.url(forResource: "FrameInterpolation", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration())
    }

    var isAvailable: Bool { model != nil }

    /// The actual tensor/image feature mapping depends on the selected model.
    /// This method deliberately returns nil when no compatible model is bundled,
    /// preventing a cross-fade from being mislabeled as AI-generated imagery.
    func generateIntermediateFrame() -> CVPixelBuffer? {
        guard model != nil else { return nil }
        return nil
    }
}
