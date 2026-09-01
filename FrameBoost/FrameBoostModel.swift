import Foundation
import Combine
import AVFoundation

struct FrameBoostSettings: Equatable {
    var targetFPS: Int = 60
    var preserveAudio: Bool = true
    var quality: Double = 0.92
}

enum ProcessingMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case onDevice = "On Device"
    case cloud = "Cloud AI"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .auto: return "Best route for speed and quality"
        case .onDevice: return "Private • works offline • RIFE 4.25"
        case .cloud: return "Server GPU • internet required"
        }
    }
}

@MainActor
final class FrameBoostModel: ObservableObject {
    @Published var settings = FrameBoostSettings()
    @Published var selectedVideoURL: URL?
    @Published var outputURL: URL?
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var selectedProfile: ProcessingProfile = .tiktokPro
    @Published var processingMode: ProcessingMode = .auto
    @Published var cloudStatus: String?

    private let processor = VideoProcessor()
    private let cloudProcessor = CloudVideoProcessor()
    private var processingTask: Task<Void, Never>?

    func startProcessing() {
        guard let input = selectedVideoURL, !isProcessing else { return }
        isProcessing = true; progress = 0; errorMessage = nil; cloudStatus = nil; outputURL = nil
        let profile = selectedProfile; settings.targetFPS = profile.targetFPS; let requestedMode = processingMode
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVAsset(url: input)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "FrameBoost", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track found"]) }
                let nominal = try await track.load(.nominalFrameRate); let sourceFPS = max(Int(nominal.rounded()), 1)
                var options = VideoProcessingOptions(targetFPS: profile.targetFPS)
                switch profile {
                case .tiktokPro: options.exportWidth = 1080; options.exportHeight = 1920; options.bitrate = sourceFPS >= 60 ? 14_000_000 : 12_000_000; options.forceSDR = true
                case .smoothSlowmo: options.bitrate = 18_000_000
                case .fastRender: options.bitrate = 10_000_000
                case .extremeCar: options.bitrate = 14_000_000; options.motionBlur = true; options.motionBlurStrength = 0.55
                case .smooth60: options.bitrate = 12_000_000
                }
                let mode: ProcessingMode = requestedMode == .auto ? (cloudProcessor.isConfigured ? .cloud : .onDevice) : requestedMode
                if mode == .cloud {
                    guard cloudProcessor.isConfigured else { throw NSError(domain: "FrameBoost.Cloud", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Cloud AI is not configured. Use On Device for now."]) }
                    cloudStatus = "Uploading securely…"
                    outputURL = try await cloudProcessor.process(url: input, options: options) { [weak self] value, status in Task { @MainActor in self?.progress = value; self?.cloudStatus = status } }
                } else {
                    outputURL = try await processor.process(url: input, options: options) { [weak self] value in Task { @MainActor in self?.progress = value } }
                }
                try Task.checkCancellation(); progress = 1; isProcessing = false; processingTask = nil; cloudStatus = nil
            } catch is CancellationError { isProcessing = false; processingTask = nil; errorMessage = "Processing cancelled."; cloudStatus = nil
            } catch { isProcessing = false; processingTask = nil; errorMessage = "Export failed: \(error.localizedDescription)"; cloudStatus = nil }
        }
    }

    func process() async { startProcessing() }
    func cancel() { processingTask?.cancel(); processingTask = nil; cloudProcessor.cancel(); isProcessing = false; errorMessage = "Processing cancelled."; cloudStatus = nil }
}

/// HTTPS client for a FrameBoost-compatible cloud inference service. No API key is embedded in the IPA.
final class CloudVideoProcessor: @unchecked Sendable {
    private var task: URLSessionTask?
    var endpoint: URL? {
        guard let raw = UserDefaults.standard.string(forKey: "FrameBoostCloudEndpoint"), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
    var isConfigured: Bool { endpoint != nil }

    func process(url: URL, options: VideoProcessingOptions, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        guard let endpoint else { throw NSError(domain: "FrameBoost.Cloud", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Invalid cloud endpoint."]) }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        let boundary = "FrameBoost-\(UUID().uuidString)"; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try Data(contentsOf: url)
        let payload = try JSONSerialization.data(withJSONObject: ["targetFPS": options.targetFPS, "preserveAudio": true, "quality": 0.92])
        var body = Data(); func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"options\"\r\nContent-Type: application/json\r\n\r\n"); body.append(payload); append("\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"input.mov\"\r\nContent-Type: video/quicktime\r\n\r\n"); body.append(data); append("\r\n--\(boundary)--\r\n")
        request.httpBody = body; progress(0.05, "Uploading securely…")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NSError(domain: "FrameBoost.Cloud", code: 2003, userInfo: [NSLocalizedDescriptionKey: String(data: responseData, encoding: .utf8) ?? "Cloud service returned an error."]) }
        progress(0.75, "Downloading enhanced video…")
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any], let outputString = object["outputURL"] as? String, let outputURL = URL(string: outputString), outputURL.scheme == "https" else { throw NSError(domain: "FrameBoost.Cloud", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Cloud service did not return a valid output URL."]) }
        let (outputData, _) = try await URLSession.shared.data(from: outputURL)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBoostCloud-\(UUID().uuidString).mp4")
        try outputData.write(to: destination, options: .atomic); progress(1, "Cloud render complete"); return destination
    }
    func cancel() { task?.cancel(); task = nil }
}
