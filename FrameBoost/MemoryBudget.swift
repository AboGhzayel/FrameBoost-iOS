import Foundation

/// Lightweight memory guard for long/high-resolution video processing.
/// It never holds video frames; it only provides a conservative budget signal
/// so the processor can select a safer processing path before allocating work.
final class MemoryBudget {
    static let shared = MemoryBudget()
    private init() {}

    func shouldUseHeavyAI(width: Int, height: Int) -> Bool {
        let pixels = Int64(width) * Int64(height)
        return pixels <= 1920 * 1080 && availableMemoryMB() >= 900
    }

    func availableMemoryMB() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
    }
}
