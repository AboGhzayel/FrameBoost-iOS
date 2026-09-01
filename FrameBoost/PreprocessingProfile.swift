import Foundation

enum PreprocessingProfile: String, CaseIterable, Identifiable, Sendable {
    case turbo = "Turbo"
    case studio = "Studio"
    case motionBlur = "Motion Blur"

    var id: String { rawValue }
    var description: String {
        switch self {
        case .turbo: return "Light re-encode • smaller upload • fast AI input"
        case .studio: return "Higher bitrate • preserves more source detail before interpolation"
        case .motionBlur: return "Subtle temporal blending • smoother perceived motion"
        }
    }
    var bitrate: Int {
        switch self { case .turbo: return 8_000_000; case .studio: return 20_000_000; case .motionBlur: return 14_000_000 }
    }
    /// 0 means preserve the source frame rate; we never downsample a 60 FPS source before AI.
    var frameRate: Int { 0 }
    var blurStrength: Float {
        switch self { case .turbo, .studio: return 0; case .motionBlur: return 0.18 }
    }
}
