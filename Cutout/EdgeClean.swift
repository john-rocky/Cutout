import Foundation
import CoreGraphics
import CoreImage

/// Foreground color decontamination at matte edges.
///
/// MatAnyone returns a soft alpha matte: pixels on the subject's boundary
/// carry fractional α. At those pixels the source frame's RGB is the
/// physically-observed blend of true foreground and true background —
/// classic matting contamination. Feeding that directly into a
/// transparent composite breaks two ways:
///
/// 1. When an alpha-aware decoder (AVPlayer, image viewers) un-
///    premultiplies a low-α pixel for display, tiny chroma leftovers
///    from the original background get amplified by ~255/α —
///    producing the bright red/yellow/green speckle ring around the
///    subject that motivated this helper.
/// 2. When the sticker is dropped onto a fresh background (chat, LINE)
///    the original background's color still bleeds through the fringe
///    and tints the matte edge.
///
/// This replaces RGB at every soft-α pixel with the color of the
/// nearest confident (α ≥ 0.5) pixel, then restores the original soft
/// α. The matte edge softness is preserved; the colors underneath are
/// clean foreground everywhere.
enum EdgeClean {

    /// `dilateRadius` is in source pixels. 12 covers MatAnyone's
    /// realistic soft-zone widths at the 768×432 canvas with headroom;
    /// raise it if a wider contaminated ring is still visible around
    /// edges.
    static func cleanForeground(source: CGImage,
                                 alpha: CGImage,
                                 dilateRadius: Double = 12) -> CGImage? {
        let ciSource = CIImage(cgImage: source)
        let ciAlpha = CIImage(cgImage: alpha)
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)

        // 1. Confident-foreground mask: α ≥ 0.5 → 1, else 0.
        let confident = ciAlpha.applyingFilter("CIColorThreshold",
            parameters: ["inputThreshold": 0.5])

        // 2. Restrict source RGB to the confident area — outside
        //    becomes transparent, no contaminated color retained.
        let confidentRGB = ciSource.applyingFilter("CIBlendWithAlphaMask",
            parameters: [kCIInputMaskImageKey: confident])

        // 3. Max-dilate outward: each formerly-transparent pixel within
        //    `dilateRadius` picks up the colour of its nearest confident
        //    neighbour.
        let extended = confidentRGB.applyingFilter("CIMorphologyMaximum",
            parameters: ["inputRadius": dilateRadius])

        // 4. Swap the extended alpha (≈1 over the dilated area) for the
        //    original soft matte. RGB now carries clean foreground
        //    colour in the entire matte + fringe region; α follows the
        //    real soft matte.
        let recombined = extended.applyingFilter("CIBlendWithAlphaMask",
            parameters: [kCIInputMaskImageKey: ciAlpha])

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(recombined, from: extent)
    }
}
