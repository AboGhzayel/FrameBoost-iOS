import Foundation
import AVFoundation

public enum FrameRateValidationError: Error, LocalizedError {
    case noVideoTrack
    case invalidFrameRate(Double)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Output contains no video track"
        case .invalidFrameRate(let fps):
            return String(format: "Output frame rate is %.2f FPS; expected 60 FPS", fps)
        }
    }
}

public struct FrameRateValidator {
    public init() {}

    public func validate(url: URL, tolerance: Double = 0.75) async throws {
        let asset = AVAsset(url: url)
        guard let tracks = try await loadVideoTracks(asset) else {
            throw FrameRateValidationError.noVideoTrack
        }
        guard let track = tracks.first else {
            throw FrameRateValidationError.noVideoTrack
        }
        let nominal = try await loadNominalFrameRate(track)
        let fps = Double(nominal)
        guard fps > 0, abs(fps - 60.0) <= tolerance else {
            throw FrameRateValidationError.invalidFrameRate(fps)
        }
    }

    private func loadVideoTracks(_ asset: AVAsset) async throws -> [AVAssetTrack]? {
        if #available(macOS 12.0, iOS 15.0, *) {
            return try await asset.loadTracks(withMediaType: .video)
        }
        return asset.tracks(withMediaType: .video)
    }

    private func loadNominalFrameRate(_ track: AVAssetTrack) async throws -> Float {
        if #available(macOS 12.0, iOS 15.0, *) {
            return try await track.load(.nominalFrameRate)
        }
        return track.nominalFrameRate
    }
}
