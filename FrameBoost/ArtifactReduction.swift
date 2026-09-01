import Foundation
import CoreVideo

final class ArtifactReduction {
    /// Suppress implausible interpolation overshoot without globally blurring the frame.
    func stabilize(generated: CVPixelBuffer, first: CVPixelBuffer, second: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(generated)
        let height = CVPixelBufferGetHeight(generated)
        guard width == CVPixelBufferGetWidth(first), height == CVPixelBufferGetHeight(first),
              width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second),
              CVPixelBufferGetPixelFormatType(generated) == kCVPixelFormatType_32BGRA else { return nil }

        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }

        CVPixelBufferLockBaseAddress(generated, .readOnly)
        CVPixelBufferLockBaseAddress(first, .readOnly)
        CVPixelBufferLockBaseAddress(second, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(second, .readOnly)
            CVPixelBufferUnlockBaseAddress(first, .readOnly)
            CVPixelBufferUnlockBaseAddress(generated, .readOnly)
        }

        guard let gBase = CVPixelBufferGetBaseAddress(generated)?.assumingMemoryBound(to: UInt8.self),
              let aBase = CVPixelBufferGetBaseAddress(first)?.assumingMemoryBound(to: UInt8.self),
              let bBase = CVPixelBufferGetBaseAddress(second)?.assumingMemoryBound(to: UInt8.self),
              let oBase = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let gr = CVPixelBufferGetBytesPerRow(generated)
        let ar = CVPixelBufferGetBytesPerRow(first)
        let br = CVPixelBufferGetBytesPerRow(second)
        let or = CVPixelBufferGetBytesPerRow(output)

        for y in 0..<height {
            let gRow = gBase.advanced(by: y * gr)
            let aRow = aBase.advanced(by: y * ar)
            let bRow = bBase.advanced(by: y * br)
            let oRow = oBase.advanced(by: y * or)
            for x in 0..<width {
                let i = x * 4
                for c in 0..<3 {
                    let g = Float(gRow[i + c])
                    let a = Float(aRow[i + c])
                    let b = Float(bRow[i + c])
                    let low = min(a, b) - 22.0
                    let high = max(a, b) + 22.0
                    let clamped = min(max(g, low), high)
                    let corrected = abs(g - clamped) > 0 ? (0.65 * clamped + 0.35 * g) : g
                    oRow[i + c] = UInt8(clamping: Int(corrected.rounded()))
                }
                oRow[i + 3] = 255
            }
        }
        return output
    }
}
