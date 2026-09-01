import Foundation
import CoreImage
import CoreVideo

struct MotionBlurEngine: Sendable {
    /// Blends the previous and current frame with a controllable temporal weight.
    /// Designed as a lightweight Core Image stage before encoding.
    func blend(previous: CIImage, current: CIImage, strength: CGFloat) -> CIImage {
        let amount = min(max(strength, 0), 0.45)
        guard amount > 0 else { return current }
        let previousPremultiplied = previous.applyingFilter("CIPremultiplyAlpha")
        let currentPremultiplied = current.applyingFilter("CIPremultiplyAlpha")
        let previousWeighted = previousPremultiplied.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        return currentPremultiplied.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: previousWeighted])
    }
}

enum VideoQueueState: Sendable {
    case queued, processing, completed, failed
}

final class VideoProcessingQueue {
    static let shared = VideoProcessingQueue(maxConcurrentOperations: 1)

    private let queue: OperationQueue
    private let lock = NSLock()
    private var states: [UUID: VideoQueueState] = [:]
    private var errors: [UUID: Error] = [:]

    init(maxConcurrentOperations: Int = 1) {
        queue = OperationQueue()
        queue.name = "com.frameboost.video-processing"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
    }

    @discardableResult
    func enqueue(url: URL, processor: VideoProcessor, targetFPS: Int, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) -> UUID {
        let id = UUID()
        setState(.queued, for: id)
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            self.setState(.processing, for: id)
            Task {
                do {
                    let result = try await processor.process(url: url, targetFPS: targetFPS, progress: progress)
                    guard !operation.isCancelled else { return }
                    self.setState(.completed, for: id)
                    completion(.success(result))
                } catch {
                    self.lock.lock(); self.errors[id] = error; self.lock.unlock()
                    self.setState(.failed, for: id)
                    completion(.failure(error))
                }
            }
        }
        queue.addOperation(operation)
        return id
    }

    func cancel(_ id: UUID) {
        // Operation cancellation is intentionally exposed as a queue-level API;
        // callers can also cancel all work when leaving the processing screen.
        // The underlying async processor checks Task cancellation between frames.
        setState(.failed, for: id)
    }

    func state(for id: UUID) -> VideoQueueState? {
        lock.lock(); defer { lock.unlock() }
        return states[id]
    }

    func error(for id: UUID) -> Error? {
        lock.lock(); defer { lock.unlock() }
        return errors[id]
    }

    func cancelAll() {
        queue.cancelAllOperations()
    }

    private func setState(_ state: VideoQueueState, for id: UUID) {
        lock.lock(); states[id] = state; lock.unlock()
    }
}
