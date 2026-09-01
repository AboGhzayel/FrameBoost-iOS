import Foundation
import CoreImage

struct MotionBlurEngine: Sendable {
    func blend(previous: CIImage, current: CIImage, strength: CGFloat) -> CIImage {
        let amount = min(max(strength, 0), 0.45)
        guard amount > 0 else { return current }
        let previousWeighted = previous.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
        ])
        return current.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: previousWeighted])
    }
}

enum VideoQueueState: Sendable { case queued, processing, completed, failed, cancelled }

final class VideoProcessingQueue {
    static let shared = VideoProcessingQueue(maxConcurrentOperations: 1)
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var states: [UUID: VideoQueueState] = [:]
    private var operations: [UUID: Operation] = [:]
    private var errors: [UUID: Error] = [:]

    init(maxConcurrentOperations: Int = 1) {
        queue.name = "com.frameboost.video-processing"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
    }

    @discardableResult
    func enqueue(url: URL, processor: VideoProcessor, targetFPS: Int, motionBlurStrength: CGFloat = 0, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) -> UUID {
        let id = UUID()
        setState(.queued, for: id)
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            if self.isCancelled(id) { return }
            self.setState(.processing, for: id)
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<URL, Error>?
            let task = Task {
                do {
                    var options = VideoProcessingOptions(targetFPS: targetFPS)
                    options.motionBlur = motionBlurStrength > 0
                    options.motionBlurStrength = motionBlurStrength
                    let output = try await processor.process(url: url, options: options, progress: progress)
                    result = .success(output)
                } catch { result = .failure(error) }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                if self.isCancelled(id) { task.cancel(); semaphore.wait(); self.setState(.cancelled, for: id); return }
            }
            if self.isCancelled(id) { self.setState(.cancelled, for: id); return }
            guard let result else { return }
            switch result {
            case .success(let output): self.setState(.completed, for: id); completion(.success(output))
            case .failure(let error):
                self.lock.lock(); self.errors[id] = error; self.lock.unlock()
                self.setState(.failed, for: id); completion(.failure(error))
            }
        }
        lock.lock(); operations[id] = operation; lock.unlock()
        queue.addOperation(operation)
        return id
    }

    func cancel(_ id: UUID) { lock.lock(); let operation = operations[id]; lock.unlock(); operation?.cancel(); setState(.cancelled, for: id) }
    func state(for id: UUID) -> VideoQueueState? { lock.lock(); defer { lock.unlock() }; return states[id] }
    func error(for id: UUID) -> Error? { lock.lock(); defer { lock.unlock() }; return errors[id] }
    func cancelAll() { queue.cancelAllOperations(); lock.lock(); let ids = Array(operations.keys); lock.unlock(); ids.forEach { setState(.cancelled, for: $0) } }
    private func isCancelled(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return operations[id]?.isCancelled == true || states[id] == .cancelled }
    private func setState(_ state: VideoQueueState, for id: UUID) { lock.lock(); states[id] = state; lock.unlock() }
}
