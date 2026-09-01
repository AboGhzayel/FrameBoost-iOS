import Foundation
import AVFoundation

struct PlatformExportProfile {
    let name: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let codec: AVVideoCodecType
}

/// Conservative presets for short-form vertical video. These are export
/// recommendations, not claims about any platform's private encoder settings.
enum PlatformOptimizer {
    static func profile(for platform: String, sourceWidth: Int, sourceHeight: Int, sourceFPS: Int) -> PlatformExportProfile {
        let portrait = sourceHeight >= sourceWidth
        let width = portrait ? 1080 : min(sourceWidth, 1920)
        let height = portrait ? 1920 : min(sourceHeight, 1080)
        let fps = sourceFPS >= 60 ? min(sourceFPS, 120) : 60
        let bitrate = fps >= 120 ? 18_000_000 : 12_000_000
        let normalized = platform.lowercased()
        let name = normalized.contains("youtube") ? "YouTube Shorts" : normalized.contains("instagram") ? "Instagram Reels" : "TikTok"
        return PlatformExportProfile(name: name, width: width, height: height, fps: fps, bitrate: bitrate, codec: .h264)
    }
}
