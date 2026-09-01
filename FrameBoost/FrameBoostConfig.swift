import Foundation

struct FrameBoostConfig: Sendable {
    let multiplier: Int
    let outputFPS: Double?
    let preserveAudio: Bool

    init(multiplier: Int = 2, sourceFPS: Double? = nil, preserveAudio: Bool = true) {
        precondition(multiplier == 2 || multiplier == 4, "FrameBoost supports 2x or 4x")
        self.multiplier = multiplier
        self.outputFPS = sourceFPS.map { min($0 * Double(multiplier), 120) }
        self.preserveAudio = preserveAudio
    }
}
