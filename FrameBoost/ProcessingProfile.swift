import Foundation

enum ProcessingProfile: String, CaseIterable, Identifiable {
    case smooth60 = "Smooth 60"
    case extremeCar = "Extreme Car"
    case smoothSlowmo = "Smooth Slowmo"
    case fastRender = "Fast Render"
    case tiktokPro = "TikTok Pro"
    var id: String { rawValue }
    var targetFPS: Int { self == .smoothSlowmo ? 120 : 60 }
    var usesOpticalFlow: Bool { self != .fastRender }
    var description: String { rawValue }
}

enum PreprocessingProfile: String, CaseIterable, Identifiable, Sendable {
    case turbo = "Turbo"
    case studio = "Studio"
    case motionBlur = "Motion Blur"
    var id: String { rawValue }
    var bitrate: Int {
        switch self {
        case .turbo: return 8_000_000
        case .studio: return 20_000_000
        case .motionBlur: return 16_000_000
        }
    }
    var blurStrength: Double { self == .motionBlur ? 0.22 : 0.0 }
}
