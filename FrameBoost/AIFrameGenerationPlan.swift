import Foundation
import CoreML
import CoreVideo

/// 60 FPS-only AI contract. AI generation is deliberately disabled for native
/// 60 FPS input: there is no reason to synthesize frames when the source already
/// contains the required cadence.
struct AIFrameGenerationPlan: Sendable {
    let inputFPS: Double
    let outputFPS: Double = 60
    let factor: Int = 1
    let modelName: String = "RIFE-4.25"

    var isNative60: Bool { inputFPS >= 59.5 }
    var needsGeneration: Bool { false }

    static func for60FPS(input: Double) -> Self {
        Self(inputFPS: max(input, 1))
    }
}

/// Reserved for future AI enhancement of existing 60 FPS frames.
/// RIFE is not invoked for 60→60 because interpolation would only add cost
/// and can introduce artifacts without increasing temporal resolution.
final class AIFrameGenerator {
    private let model: MLModel?

    init() {
        guard let url = Bundle.main.url(forResource: "RIFE_4_25", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration())
    }

    var isAvailable: Bool { model != nil }

    func enhance60FPSFrame(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        // Until an enhancement model with a validated Core ML schema is bundled,
        // preserve the original frame rather than performing fake AI processing.
        return frame
    }
}
