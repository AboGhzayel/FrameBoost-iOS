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
        let normalized = platform.lowercased()
        let shortForm = normalized.contains("tiktok") || normalized.contains("instagram") || normalized.contains("short")
        let sourcePortrait = sourceHeight >= sourceWidth

        let width: Int
        let height: Int
        if shortForm {
            width = 1080
            height = 1920
        } else if sourcePortrait {
            width = min(sourceWidth, 1080)
            height = min(sourceHeight, 1920)
        } else {
            width = min(sourceWidth, 1920)
            height = min(sourceHeight, 1080)
        }

        let fps = sourceFPS >= 60 ? min(sourceFPS, 120) : 60
        let bitrate = fps >= 120 ? 18_000_000 : 12_000_000
        let name: String
        if normalized.contains("youtube") { name = "YouTube Shorts" }
        else if normalized.contains("instagram") { name = "Instagram Reels" }
        else { name = "TikTok Pro" }

        return PlatformExportProfile(name: name, width: width, height: height, fps: fps, bitrate: bitrate, codec: .h264, requiresSDR: true)
    }
}
