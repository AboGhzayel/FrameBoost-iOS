import Foundation
import CoreML
import CoreVideo

/// RIFE integration point for true 2x frame interpolation.
/// The engine intentionally fails closed when the real Core ML model is not bundled.
final class RIFEEngine {
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

    /// Returns an interpolated frame only when a validated RIFE Core ML model is available.
    /// The actual model input/output names and tensor layout must match the converted model;
    /// no guessed schema is executed at runtime.
    func interpolate(first: CVPixelBuffer, second: CVPixelBuffer) throws -> CVPixelBuffer {
        guard model != nil else {
            throw NSError(domain: "FrameBoost.RIFE", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "RIFE Core ML model is not bundled or is unavailable"
            ])
        }
        guard CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(second),
              CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(second) else {
            throw NSError(domain: "FrameBoost.RIFE", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "RIFE input frames must have identical dimensions"
            ])
        }
        throw NSError(domain: "FrameBoost.RIFE", code: 1003, userInfo: [
            NSLocalizedDescriptionKey: "RIFE model schema has not been validated for this build"
        ])
    }
}
