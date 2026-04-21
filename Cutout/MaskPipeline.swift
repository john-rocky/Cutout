import Foundation
import CoreGraphics
import CoreImage
import Vision
import CoreMLZoo

/// First-frame mask generation for MatAnyone seeding.
///
/// Tries in order:
/// 1. Vision `VNGeneratePersonSegmentationRequest(.accurate)` — free, fast,
///    works for most human subjects.
/// 2. CoreMLZoo `BackgroundRemovalRequest` (RMBG-1.4) — salient subject
///    detection for pets / products / objects when person segmentation
///    produces a near-empty mask.
///
/// Output is a binarised single-channel CGImage matching `targetSize`,
/// ready to hand to `VideoMattingSession`.
enum MaskPipeline {

    enum SourceModel: Equatable {
        case person
        case salient
    }

    struct MaskResult {
        let mask: CGImage
        let source: SourceModel
    }

    /// Sum of mask pixels / total pixels. Below 0.5% we consider Vision
    /// person segmentation to have "found nothing" and fall back to RMBG.
    private static let personCoverageFloor: Double = 0.005

    static func generate(from firstFrame: CGImage,
                         targetSize: CGSize,
                         preferredSource: SourceModel = .person) async throws -> MaskResult {
        if preferredSource == .person,
           let mask = try await personMask(from: firstFrame, targetSize: targetSize),
           coverage(of: mask) > personCoverageFloor {
            return MaskResult(mask: mask, source: .person)
        }
        // Fall through to salient subject matting.
        let salient = try await salientMask(from: firstFrame, targetSize: targetSize)
        return MaskResult(mask: salient, source: .salient)
    }

    // MARK: - Vision Person Segmentation

    private static func personMask(from image: CGImage,
                                    targetSize: CGSize) async throws -> CGImage? {
        try await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([req])
            guard let observation = req.results?.first else { return nil }
            return Self.resize(pixelBuffer: observation.pixelBuffer, to: targetSize)
        }.value
    }

    // MARK: - Salient subject (RMBG)

    private static func salientMask(from image: CGImage,
                                     targetSize: CGSize) async throws -> CGImage {
        let result = try await BackgroundRemovalRequest().perform(on: image)
        // Resize the full-res mask to `targetSize`.
        let ciMask = CIImage(cgImage: result.mask)
        let sx = targetSize.width  / ciMask.extent.width
        let sy = targetSize.height / ciMask.extent.height
        let scaled = ciMask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled,
                                          from: CGRect(origin: .zero, size: targetSize)) else {
            return result.mask
        }
        return cg
    }

    // MARK: - Helpers

    private static func resize(pixelBuffer: CVPixelBuffer,
                                to size: CGSize) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = size.width  / ci.extent.width
        let sy = size.height / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(scaled, from: CGRect(origin: .zero, size: size))
    }

    private static func coverage(of mask: CGImage) -> Double {
        let w = mask.width, h = mask.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &bytes, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: UInt64 = 0
        for v in bytes where v > 127 { sum += 1 }
        return Double(sum) / Double(w * h)
    }
}
