import Foundation
import CoreML
import CoreVideo

struct AIFrameGenerationPlan: Sendable {
    let inputFPS: Double
    let outputFPS: Double = 60
    let factor: Int
    let modelName: String = "RIFE-4.25"

    var isNative60: Bool { inputFPS >= 59.0 }
    var needsGeneration: Bool { !isNative60 && inputFPS > 0 }

    static func make(input: Double) -> Self {
        Self(inputFPS: max(input, 1), factor: input < 59.0 ? 2 : 1)
    }
}

final class AIFrameGenerator {
    private let model: MLModel?

    init() {
        guard let url = Bundle.main.url(forResource: "RIFE_4_25", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }

    var isAvailable: Bool { model != nil }

    func enhance60FPSFrame(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        frame
    }
}
