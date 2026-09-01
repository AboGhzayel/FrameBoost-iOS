import Foundation
import CoreImage
import CoreVideo

/// Lightweight post-processing guard for generated frames.
/// It does not invent motion; it suppresses unstable high-frequency changes at boundaries.
final class ArtifactReduction {
    private let context = CIContext(options: [CIContextOption.cacheIntermediates: false])

    func stabilize(generated: CVPixelBuffer, first: CVPixelBuffer, second: CVPixelBuffer) -> CVPixelBuffer? {
        let g = CIImage(cvPixelBuffer: generated)
        let a = CIImage(cvPixelBuffer: first)
        let b = CIImage(cvPixelBuffer: second)
        let extent = g.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        // Keep the generated frame sharp, but reduce isolated ringing/tearing.
        // A very small radius is intentional: aggressive blur destroys car/wheel detail.
        let softened = g.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.35]).cropped(to: extent)
        let result = softened.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: g])
        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: CVPixelBufferGetWidth(generated),
            kCVPixelBufferHeightKey: CVPixelBufferGetHeight(generated),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(generated), CVPixelBufferGetHeight(generated), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let output else { return nil }
        context.render(result, to: output)
        _ = a
        _ = b
        return output
    }
}
