import Foundation

enum PreprocessingProfile: String, CaseIterable, Identifiable, Sendable {
    case turbo = "Turbo"
    case studio = "Studio"
    case motionBlur = "Motion Blur"

    var id: String { rawValue }
    var description: String {
        switch self {
        case .turbo: return "Fast re-encode • balanced bitrate • optimized for AI input"
        case .studio: return "Higher bitrate • preserves more source detail before interpolation"
        case .motionBlur: return "Adds subtle temporal blending before AI processing for smoother motion"
        }
    }
    var bitrate: Int {
        switch self { case .turbo: return 8_000_000; case .studio: return 20_000_000; case .motionBlur: return 14_000_000 }
    }
    var frameRate: Int { 30 }
    var blurStrength: Float {
        switch self { case .turbo, .studio: return 0; case .motionBlur: return 0.18 }
    }
}
