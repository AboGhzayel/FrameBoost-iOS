import Foundation
import CoreML
import CoreVideo

/// Real RIFE 4.25 Core ML inference for 2x frame interpolation.
/// The bundled model is a 256x256 RGB-pair graph. Larger frames are processed
/// with overlapping tiles to keep peak memory bounded and reduce tile seams.
final class RIFEEngine {
    private let model: MLModel?
    private let tile = 256
    private let overlap = 64

    init() {
        guard let url = Bundle.main.url(forResource: "RIFE_4_25", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }

    var isAvailable: Bool { model != nil }

    func interpolate(first: CVPixelBuffer, second: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let model else { throw error(1001, "RIFE Core ML model is unavailable") }
        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)
        guard width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second) else {
            throw error(1002, "RIFE input frames must have identical dimensions")
        }
        guard width >= 2, height >= 2 else { throw error(1003, "RIFE input is too small") }

        guard let output = makeBuffer(width: width, height: height) else {
            throw error(1004, "Unable to allocate RIFE output buffer")
        }
        CVPixelBufferLockBaseAddress(first, .readOnly)
        CVPixelBufferLockBaseAddress(second, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(second, .readOnly)
            CVPixelBufferUnlockBaseAddress(first, .readOnly)
        }

        guard let base0 = CVPixelBufferGetBaseAddress(first),
              let base1 = CVPixelBufferGetBaseAddress(second),
              let outBase = CVPixelBufferGetBaseAddress(output) else {
            throw error(1005, "RIFE pixel buffer base address unavailable")
        }

        let row0 = CVPixelBufferGetBytesPerRow(first)
        let row1 = CVPixelBufferGetBytesPerRow(second)
        let outRow = CVPixelBufferGetBytesPerRow(output)
        let outCapacity = width * height * 4
        var accum = [Float](repeating: 0, count: outCapacity)
        var weights = [Float](repeating: 0, count: width * height)
        let step = tile - overlap

        for y in stride(from: 0, to: height, by: step) {
            let y0 = min(y, max(height - tile, 0))
            for x in stride(from: 0, to: width, by: step) {
                let x0 = min(x, max(width - tile, 0))
                let input = try makeInput(base0: base0, base1: base1, row0: row0, row1: row1, width: width, height: height, x: x0, y: y0)
                let features = try MLDictionaryFeatureProvider(dictionary: ["frames": MLFeatureValue(multiArray: input)])
                let result = try model.prediction(from: features)
                guard let array = result.featureValue(for: "frame")?.multiArrayValue else {
                    throw error(1006, "RIFE model did not return a frame tensor")
                }
                try accumulate(array: array, into: &accum, weights: &weights, width: width, height: height, x: x0, y: y0)
                if x0 + tile >= width { break }
            }
            if y0 + tile >= height { break }
        }

        let outputPtr = outBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let dst = outputPtr.advanced(by: y * outRow)
            for x in 0..<width {
                let p = y * width + x
                let w = max(weights[p], 0.0001)
                let o = p * 4
                // RGB model output -> BGRA pixel buffer.
                dst[x * 4] = UInt8(clamping: Int((accum[o + 2] / w) * 255.0))
                dst[x * 4 + 1] = UInt8(clamping: Int((accum[o + 1] / w) * 255.0))
                dst[x * 4 + 2] = UInt8(clamping: Int((accum[o] / w) * 255.0))
                dst[x * 4 + 3] = 255
            }
        }
        return output
    }

    private func makeInput(base0: UnsafeMutableRawPointer, base1: UnsafeMutableRawPointer, row0: Int, row1: Int, width: Int, height: Int, x: Int, y: Int) throws -> MLMultiArray {
        let input = try MLMultiArray(shape: [1, 6, tile, tile], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        let strideH = tile * tile
        let strideC = strideH
        let p0 = base0.assumingMemoryBound(to: UInt8.self)
        let p1 = base1.assumingMemoryBound(to: UInt8.self)
        for ty in 0..<tile {
            let sy = min(max(y + ty, 0), height - 1)
            let r0 = p0.advanced(by: sy * row0)
            let r1 = p1.advanced(by: sy * row1)
            for tx in 0..<tile {
                let sx = min(max(x + tx, 0), width - 1)
                let b0 = sx * 4
                let b1 = sx * 4
                let i = ty * tile + tx
                // RGB, [0,1].
                ptr[0 * strideC + i] = Float(r0[b0 + 2]) / 255.0
                ptr[1 * strideC + i] = Float(r0[b0 + 1]) / 255.0
                ptr[2 * strideC + i] = Float(r0[b0]) / 255.0
                ptr[3 * strideC + i] = Float(r1[b1 + 2]) / 255.0
                ptr[4 * strideC + i] = Float(r1[b1 + 1]) / 255.0
                ptr[5 * strideC + i] = Float(r1[b1]) / 255.0
            }
        }
        return input
    }

    private func accumulate(array: MLMultiArray, into accum: inout [Float], weights: inout [Float], width: Int, height: Int, x: Int, y: Int) throws {
        guard array.count >= 3 * tile * tile else { throw error(1007, "Unexpected RIFE output tensor shape") }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = tile * tile
        for ty in 0..<tile {
            let py = y + ty
            if py >= height { continue }
            for tx in 0..<tile {
                let px = x + tx
                if px >= width { continue }
                let wx = edgeWeight(tx)
                let wy = edgeWeight(ty)
                let w = max(wx * wy, 0.05)
                let i = ty * tile + tx
                let p = py * width + px
                let o = p * 4
                accum[o] += ptr[i] * w
                accum[o + 1] += ptr[plane + i] * w
                accum[o + 2] += ptr[2 * plane + i] * w
                weights[p] += w
            }
        }
    }

    private func edgeWeight(_ index: Int) -> Float {
        let edge = min(index, tile - 1 - index)
        if edge >= overlap / 2 { return 1.0 }
        let t = Float(edge) / Float(max(overlap / 2, 1))
        return 0.5 - 0.5 * cosf(Float.pi * t)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "FrameBoost.RIFE", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
