import Foundation

enum ProcessingProfile: String, CaseIterable, Identifiable {
    case smooth60 = "Smooth 60"
    case extremeCar = "Extreme Car"
    case smoothSlowmo = "Smooth Slowmo"
    case fastRender = "Fast Render"
    case tiktokPro = "TikTok Pro"

    var id: String { rawValue }

    var targetFPS: Int {
        switch self {
        case .smoothSlowmo: return 120
        default: return 60
        }
    }

    var usesOpticalFlow: Bool {
        self != .fastRender
    }

    var description: String {
        switch self {
        case .smooth60: return "Balanced AI-ready 30→60 FPS processing"
        case .extremeCar: return "Motion-focused processing for fast vehicles and action"
        case .smoothSlowmo: return "Higher frame rate for smoother slow-motion footage"
        case .fastRender: return "Fast, lightweight processing with minimal AI work"
        case .tiktokPro: return "Vertical short-form export optimized for TikTok"
        }
    }
}
