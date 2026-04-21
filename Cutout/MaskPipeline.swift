import Foundation
import CoreGraphics
import CoreImage
import Vision

/// First-frame mask generation for MatAnyone seeding. 100% on-device,
/// uses only Apple Vision — no extra model download.
///
/// Tries in order:
/// 1. `VNGeneratePersonSegmentationRequest(.accurate)` — fast, high
///    quality for human subjects.
/// 2. `VNGenerateForegroundInstanceMaskRequest` (iOS 17+) — salient-
///    subject foreground mask for pets, products, and any object
///    Person Segmentation can't pick up.
///
/// Output: binarised single-channel CGImage at `targetSize`, ready to
/// hand to `VideoMattingSession`.
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
    /// person segmentation to have "found nothing" and fall back to the
    /// foreground-instance request.
    private static let personCoverageFloor: Double = 0.005

    static func generate(from firstFrame: CGImage,
                         targetSize: CGSize,
                         preferredSource: SourceModel = .person) async throws -> MaskResult {
        if preferredSource == .person,
           let mask = try await personMask(from: firstFrame, targetSize: targetSize),
           coverage(of: mask) > personCoverageFloor {
            return MaskResult(mask: mask, source: .person)
        }
        // Fall through to foreground-instance salient matting.
        if let salient = try await foregroundInstanceMask(from: firstFrame,
                                                           targetSize: targetSize) {
            return MaskResult(mask: salient, source: .salient)
        }
        // Last-ditch: an empty mask lets MatAnyone's decoder compute its
        // own initial alpha without a hint (lower quality but still runs).
        return MaskResult(mask: blankMask(size: targetSize), source: .salient)
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

    // MARK: - Foreground-Instance Mask (iOS 17+)

    private static func foregroundInstanceMask(from image: CGImage,
                                                 targetSize: CGSize) async throws -> CGImage? {
        try await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([req])
            guard let observation = req.results?.first else { return nil }
            let allInstances = observation.allInstances
            guard !allInstances.isEmpty else { return nil }
            // Merged mask of every detected salient instance — for
            // MatAnyone's first-frame seed we want "everything the user
            // intended to cut out" in one layer.
            let merged = try observation.generateScaledMaskForImage(
                forInstances: allInstances,
                from: handler)
            return Self.resize(pixelBuffer: merged, to: targetSize)
        }.value
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

    /// Empty (all-black) mask used only as a fall-through when Vision
    /// produces nothing — MatAnyone will decode its own first-frame
    /// alpha without a hint.
    private static func blankMask(size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let bytes = [UInt8](repeating: 0, count: w * h)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }
}
