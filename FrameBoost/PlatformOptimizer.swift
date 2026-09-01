import Foundation
import AVFoundation

struct PlatformExportProfile {
    let name: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let codec: AVVideoCodecType
    let requiresSDR: Bool
}

enum PlatformOptimizer {
    static func profile(for platform: String, sourceWidth: Int, sourceHeight: Int, sourceFPS: Int) -> PlatformExportProfile {
        let portrait = sourceHeight >= sourceWidth
        let isShortForm = platform.lowercased().contains("tiktok") || platform.lowercased().contains("instagram") || platform.lowercased().contains("short")
        let width: Int
        let height: Int
        if isShortForm && portrait {
            width = 1080; height = 1920
        } else if isShortForm {
            width = 1080; height = 1920
        } else {
            width = min(sourceWidth, 1920); height = min(sourceHeight, 1080)
        }
        let fps = sourceFPS >= 60 ? min(sourceFPS, 120) : 60
        let bitrate = fps >= 120 ? 18_000_000 : 12_000_000
        let normalized = platform.lowercased()
        let name = normalized.contains("youtube") ? "YouTube Shorts" : normalized.contains("instagram") ? "Instagram Reels" : "TikTok Pro"
        return PlatformExportProfile(name: name, width: width, height: height, fps: fps, bitrate: bitrate, codec: .h264, requiresSDR: true)
    }
}
