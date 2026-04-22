import Foundation
import AVFoundation
import CoreGraphics
import Compression
import UIKit

/// Encode a sequence of frames from a transparent-HEVC video into a
/// **LINE-compliant APNG** sticker.
///
/// LINE Creators Market animation sticker rules
/// (https://creator.line.me/en/guideline/animationsticker/):
///
/// - Canvas up to **320 × 270 px**, longer side **≥ 270** (if the height is
///   the longer side it must be *exactly* 270).
/// - **5 – 20 frames** per APNG.
/// - Playback time: **1, 2, 3, or 4 seconds** (integers only). 1 – 4 loops
///   whose combined length stays ≤ 4 s.
/// - RGB, transparent background, `.png` extension.
/// - **≤ 1 MB** per file, ZIP of all files ≤ 60 MB.
///
/// This encoder emits straight-alpha RGBA APNGs with filter type 0 per row
/// (PNG filter = None) compressed with Apple's `Compression` framework
/// (raw deflate) wrapped in the mandatory zlib header/adler32 trailer.
enum APNGExporter {

    enum APNGError: LocalizedError {
        case noVideoTrack
        case frameDecode(String)
        case deflateFailed
        case oversize(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "Source clip has no video track."
            case .frameDecode(let m):
                return "Couldn't sample a frame: \(m)"
            case .deflateFailed:
                return "APNG compression failed."
            case .oversize(let b):
                return "APNG \(b / 1024) KB exceeds LINE's 1 MB limit. Try fewer frames or a shorter playback time."
            }
        }
    }

    public struct Params: Sendable {
        /// LINE allows 1, 2, 3, or 4 seconds only.
        public var playbackSeconds: Int
        /// 5 … 20. Auto-picked based on playback seconds if nil.
        public var frameCount: Int?
        /// APNG's num_plays. LINE requires this × playbackSeconds ≤ 4.
        public var loops: Int

        public init(playbackSeconds: Int = 2,
                    frameCount: Int? = nil,
                    loops: Int = 1) {
            precondition([1, 2, 3, 4].contains(playbackSeconds),
                         "LINE accepts 1/2/3/4 seconds only")
            self.playbackSeconds = playbackSeconds
            self.frameCount = frameCount
            self.loops = loops
        }
    }

    public struct Output {
        public let apngURL: URL          // the main animated sticker
        public let mainImageURL: URL     // 240×240 static PNG
        public let tabImageURL: URL      // 96×74 static PNG
        public let dimensions: (width: Int, height: Int)
        public let frameCount: Int
        public let fileBytes: Int
    }

    // MARK: - Entry point

    public static func export(from transparentHEVCURL: URL,
                              params: Params,
                              to directory: URL? = nil) async throws -> Output {
        let asset = AVURLAsset(url: transparentHEVCURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw APNGError.noVideoTrack
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = natural.applying(transform)
        let srcW = Int(abs(displaySize.width))
        let srcH = Int(abs(displaySize.height))

        let (targetW, targetH) = computeLINEDimensions(srcW: srcW, srcH: srcH)
        let frameCount = clamp(params.frameCount ?? defaultFrameCount(for: params.playbackSeconds),
                               5, 20)

        // Sample frames evenly across source duration.
        let duration = try await asset.load(.duration).seconds
        let times: [NSValue] = (0..<frameCount).map { i in
            let t = frameCount == 1
                ? 0
                : duration * Double(i) / Double(frameCount - 1)
            return NSValue(time: CMTime(seconds: t, preferredTimescale: 600))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: targetW * 2, height: targetH * 2)

        var rgbaFrames: [[UInt8]] = []
        rgbaFrames.reserveCapacity(frameCount)
        for t in times {
            let cg = try await cgImage(at: t.timeValue, from: generator)
            rgbaFrames.append(renderStraightRGBA(cg, width: targetW, height: targetH))
        }

        // delay = playbackSeconds / frameCount per frame. APNG stores as two UInt16.
        // Pick numerator/denominator so the fraction is exact and small.
        let (delayNum, delayDen) = frameDelay(playbackSeconds: params.playbackSeconds,
                                               frameCount: frameCount)

        let numPlays = UInt32(max(1, min(4, params.loops)))

        let apngData = buildAPNG(width: targetW,
                                 height: targetH,
                                 frames: rgbaFrames,
                                 delayNum: delayNum,
                                 delayDen: delayDen,
                                 numPlays: numPlays)

        let outDir = directory ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: outDir,
                                                 withIntermediateDirectories: true)
        let stem = "line_sticker_\(UUID().uuidString.prefix(8))"
        let apngURL = outDir.appendingPathComponent("\(stem).png")
        let mainURL = outDir.appendingPathComponent("\(stem)_main.png")
        let tabURL  = outDir.appendingPathComponent("\(stem)_tab.png")

        try apngData.write(to: apngURL)

        if apngData.count > 1_000_000 {
            throw APNGError.oversize(bytes: apngData.count)
        }

        // Static main 240×240 and tab 96×74 from the middle frame so it's
        // representative (LINE scales it up as a preview).
        let midIndex = rgbaFrames.count / 2
        let midFrame = try await cgImage(at: times[midIndex].timeValue, from: generator)
        try writeStaticPNG(frame: midFrame,
                           canvasW: 240, canvasH: 240, to: mainURL)
        try writeStaticPNG(frame: midFrame,
                           canvasW: 96, canvasH: 74, to: tabURL)

        return Output(apngURL: apngURL,
                      mainImageURL: mainURL,
                      tabImageURL: tabURL,
                      dimensions: (targetW, targetH),
                      frameCount: frameCount,
                      fileBytes: apngData.count)
    }

    // MARK: - Low-level public APIs (used by sparse pipeline)

    /// Encode already-rendered straight-alpha RGBA frames as an APNG. Does
    /// not touch the filesystem; caller writes the returned bytes.
    public static func encodeAnimatedAPNG(frames rgbaFrames: [[UInt8]],
                                           width: Int, height: Int,
                                           playbackSeconds: Int,
                                           loops: Int) -> Data {
        let (num, den) = frameDelay(playbackSeconds: playbackSeconds,
                                     frameCount: rgbaFrames.count)
        return buildAPNG(width: width, height: height,
                         frames: rgbaFrames,
                         delayNum: num, delayDen: den,
                         numPlays: UInt32(max(1, min(4, loops))))
    }

    /// Encode a single straight-alpha RGBA buffer as a static PNG (IHDR +
    /// IDAT + IEND only, no animation chunks).
    public static func encodeStaticPNG(rgba: [UInt8],
                                        width: Int, height: Int) throws -> Data {
        var out = Data()
        out.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(ihdr(width: width, height: height))
        let filtered = filterRGBA(rgba, width: width, height: height)
        guard let compressed = zlibCompress(filtered) else {
            throw APNGError.deflateFailed
        }
        out.append(chunk(type: "IDAT", data: compressed))
        out.append(chunk(type: "IEND", data: []))
        return out
    }

    /// Render a source frame + alpha mask into a straight-alpha RGBA buffer
    /// sized `(canvasW × canvasH)`. When `fitAspect == true` the source is
    /// aspect-scaled and centered with transparent padding; otherwise the
    /// source is stretched to fill.
    public static func composeSubjectRGBA(source: CGImage,
                                           alpha: CGImage,
                                           canvasW: Int, canvasH: Int,
                                           fitAspect: Bool) -> [UInt8] {
        // Decontaminate: replace matte-edge RGB with the nearest
        // confident-foreground colour before we composite. Without
        // this, the un-premultiplication loop below amplifies
        // background tint at low-α pixels by ~255/α and the APNG
        // shows a coloured halo around the subject.
        let cleaned = EdgeClean.cleanForeground(source: source, alpha: alpha) ?? source

        var raw = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        guard let ctx = CGContext(
            data: &raw, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return raw
        }
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.interpolationQuality = .high

        let drawRect: CGRect
        if fitAspect {
            let scale = min(Double(canvasW) / Double(source.width),
                            Double(canvasH) / Double(source.height))
            let dw = Int((Double(source.width) * scale).rounded())
            let dh = Int((Double(source.height) * scale).rounded())
            drawRect = CGRect(x: (canvasW - dw) / 2,
                              y: (canvasH - dh) / 2,
                              width: dw, height: dh)
        } else {
            drawRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        }

        // `cleaned` already carries (decontaminated RGB, soft α), so
        // blitting it into the premultiplied destination does the
        // right thing without an additional clip-to-mask step.
        ctx.draw(cleaned, in: drawRect)

        unpremultiplyInPlace(&raw)
        return raw
    }

    // MARK: - Dimension logic

    /// LINE rules: max 320×270, longer side ≥270, if height is longer it
    /// must be **exactly** 270.
    static func computeLINEDimensions(srcW: Int, srcH: Int) -> (Int, Int) {
        let maxW = 320, maxH = 270
        guard srcW > 0, srcH > 0 else { return (maxH, maxH) }

        if srcH > srcW {
            // Portrait → height must be exactly 270.
            let h = 270
            var w = Int((Double(270 * srcW) / Double(srcH)).rounded())
            w = min(w, maxW)
            return (even(w), h)
        }
        // Landscape or square → fit inside 320×270 while keeping max edge = 320.
        var w = maxW
        var h = Int((Double(maxW * srcH) / Double(srcW)).rounded())
        if h > maxH {
            h = maxH
            w = Int((Double(maxH * srcW) / Double(srcH)).rounded())
        }
        // Safety: enforce longer side ≥ 270 (always true since maxW=320 > 270).
        return (even(w), even(h))
    }

    private static func even(_ n: Int) -> Int { n - (n % 2) }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }

    private static func defaultFrameCount(for playbackSeconds: Int) -> Int {
        // Smoothness heuristic: 10 fps, capped at 20.
        min(20, max(5, playbackSeconds * 10))
    }

    /// Choose (num, den) so that `num/den = playbackSeconds / frameCount`.
    private static func frameDelay(playbackSeconds: Int, frameCount: Int) -> (UInt16, UInt16) {
        // Reduce common factor (GCD) so both stay in UInt16 range.
        var a = playbackSeconds
        var b = frameCount
        while b != 0 { (a, b) = (b, a % b) }
        let g = a
        let num = playbackSeconds / g
        let den = frameCount / g
        return (UInt16(num), UInt16(den))
    }

    // MARK: - Frame sampling

    private static func cgImage(at time: CMTime,
                                 from generator: AVAssetImageGenerator) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, _, error in
                if let error { cont.resume(throwing: APNGError.frameDecode(error.localizedDescription)); return }
                if let image { cont.resume(returning: image); return }
                cont.resume(throwing: APNGError.frameDecode("nil image"))
            }
        }
    }

    /// Render a CGImage into straight-alpha RGBA8 bytes. PNG requires
    /// non-premultiplied alpha; `CGBitmapContext` only writes premultiplied,
    /// so we un-premultiply afterwards.
    private static func renderStraightRGBA(_ image: CGImage, width w: Int, height h: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &raw, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return raw
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        unpremultiplyInPlace(&raw)
        return raw
    }

    /// Un-premultiply a BGRA/RGBA buffer for straight-alpha output, and
    /// clamp the weakest-α pixels to fully transparent so that rounding
    /// noise doesn't get amplified into visible colour specks at the
    /// matte edge. `α < 8` (≈3 % opacity) carries so little signal that
    /// the `v * 255 / α` division explodes on HEVC chroma-subsampling
    /// artefacts; we treat those pixels as background.
    private static func unpremultiplyInPlace(_ raw: inout [UInt8]) {
        var i = 0
        while i < raw.count {
            let a = raw[i + 3]
            if a < 8 {
                raw[i] = 0; raw[i + 1] = 0; raw[i + 2] = 0; raw[i + 3] = 0
            } else if a != 255 {
                raw[i]     = UInt8(min(255, (Int(raw[i])     * 255 + Int(a) / 2) / Int(a)))
                raw[i + 1] = UInt8(min(255, (Int(raw[i + 1]) * 255 + Int(a) / 2) / Int(a)))
                raw[i + 2] = UInt8(min(255, (Int(raw[i + 2]) * 255 + Int(a) / 2) / Int(a)))
            }
            i += 4
        }
    }

    // MARK: - APNG assembly

    private static func buildAPNG(width: Int, height: Int,
                                   frames: [[UInt8]],
                                   delayNum: UInt16, delayDen: UInt16,
                                   numPlays: UInt32) -> Data {
        var out = Data()
        out.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(ihdr(width: width, height: height))
        out.append(actl(numFrames: UInt32(frames.count), numPlays: numPlays))

        var seq: UInt32 = 0
        for (i, frame) in frames.enumerated() {
            out.append(fctl(sequence: seq,
                            width: width, height: height,
                            delayNum: delayNum, delayDen: delayDen,
                            disposeOp: 1, blendOp: 0))
            seq += 1
            let filtered = filterRGBA(frame, width: width, height: height)
            guard let compressed = zlibCompress(filtered) else { continue }
            if i == 0 {
                out.append(chunk(type: "IDAT", data: compressed))
            } else {
                var payload = uint32BE(seq)
                payload.append(contentsOf: compressed)
                out.append(chunk(type: "fdAT", data: payload))
                seq += 1
            }
        }
        out.append(chunk(type: "IEND", data: []))
        return out
    }

    // MARK: - Chunks

    private static func chunk(type: String, data: [UInt8]) -> Data {
        let typeBytes = Array(type.utf8)
        var out = Data()
        out.append(contentsOf: uint32BE(UInt32(data.count)))
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        let crc = crc32(typeBytes + data)
        out.append(contentsOf: uint32BE(crc))
        return out
    }

    private static func ihdr(width: Int, height: Int) -> Data {
        var d = [UInt8]()
        d.append(contentsOf: uint32BE(UInt32(width)))
        d.append(contentsOf: uint32BE(UInt32(height)))
        d.append(8)  // bit depth
        d.append(6)  // RGBA
        d.append(0)  // deflate
        d.append(0)  // filter method
        d.append(0)  // interlace none
        return chunk(type: "IHDR", data: d)
    }

    private static func actl(numFrames: UInt32, numPlays: UInt32) -> Data {
        var d = [UInt8]()
        d.append(contentsOf: uint32BE(numFrames))
        d.append(contentsOf: uint32BE(numPlays))
        return chunk(type: "acTL", data: d)
    }

    private static func fctl(sequence: UInt32,
                              width: Int, height: Int,
                              delayNum: UInt16, delayDen: UInt16,
                              disposeOp: UInt8, blendOp: UInt8) -> Data {
        var d = [UInt8]()
        d.append(contentsOf: uint32BE(sequence))
        d.append(contentsOf: uint32BE(UInt32(width)))
        d.append(contentsOf: uint32BE(UInt32(height)))
        d.append(contentsOf: uint32BE(0))  // x_offset
        d.append(contentsOf: uint32BE(0))  // y_offset
        d.append(UInt8((delayNum >> 8) & 0xff))
        d.append(UInt8(delayNum & 0xff))
        d.append(UInt8((delayDen >> 8) & 0xff))
        d.append(UInt8(delayDen & 0xff))
        d.append(disposeOp)
        d.append(blendOp)
        return chunk(type: "fcTL", data: d)
    }

    // MARK: - Filter + zlib

    private static func filterRGBA(_ rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        // Per-row filter type 0 (None). Simple and reliable; size larger
        // than adaptive filtering but fits the 1MB budget for typical
        // 320×270 × 20-frame stickers.
        let rowStride = width * 4
        var out = [UInt8]()
        out.reserveCapacity(height * (1 + rowStride))
        for y in 0..<height {
            out.append(0)
            let start = y * rowStride
            out.append(contentsOf: rgba[start..<(start + rowStride)])
        }
        return out
    }

    private static func zlibCompress(_ raw: [UInt8]) -> [UInt8]? {
        let capacity = raw.count * 2 + 64
        var deflate = [UInt8](repeating: 0, count: capacity)
        let n = raw.withUnsafeBufferPointer { src -> Int in
            deflate.withUnsafeMutableBufferPointer { dst -> Int in
                compression_encode_buffer(dst.baseAddress!, dst.count,
                                          src.baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        deflate.removeSubrange(n..<deflate.count)
        // Apple's COMPRESSION_ZLIB emits raw deflate — add RFC1950 wrapper.
        var wrapped: [UInt8] = [0x78, 0x9C]
        wrapped.append(contentsOf: deflate)
        let adler = adler32(raw)
        wrapped.append(contentsOf: uint32BE(adler))
        return wrapped
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let MOD: UInt32 = 65521
        for byte in bytes {
            a = (a + UInt32(byte)) % MOD
            b = (b + a) % MOD
        }
        return (b << 16) | a
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1
            }
            t[i] = c
        }
        return t
    }()

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }

    private static func uint32BE(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff),
         UInt8((v >> 16) & 0xff),
         UInt8((v >> 8)  & 0xff),
         UInt8( v        & 0xff)]
    }

    // MARK: - Static helper (main / tab images)

    private static func writeStaticPNG(frame: CGImage,
                                        canvasW: Int, canvasH: Int,
                                        to url: URL) throws {
        // Scale-to-fit into canvas, center horizontally and vertically,
        // transparent padding around the subject.
        let srcW = frame.width, srcH = frame.height
        let scale = min(Double(canvasW) / Double(srcW),
                        Double(canvasH) / Double(srcH))
        let drawW = Int(Double(srcW) * scale)
        let drawH = Int(Double(srcH) * scale)
        let dx = (canvasW - drawW) / 2
        let dy = (canvasH - drawH) / 2

        var raw = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        guard let ctx = CGContext(
            data: &raw, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw APNGError.frameDecode("main image context")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.interpolationQuality = .high
        ctx.draw(frame, in: CGRect(x: dx, y: dy, width: drawW, height: drawH))
        unpremultiplyInPlace(&raw)

        // Single-frame PNG — no acTL/fcTL/fdAT, just IHDR+IDAT+IEND.
        var out = Data()
        out.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(ihdr(width: canvasW, height: canvasH))
        let filtered = filterRGBA(raw, width: canvasW, height: canvasH)
        guard let compressed = zlibCompress(filtered) else {
            throw APNGError.deflateFailed
        }
        out.append(chunk(type: "IDAT", data: compressed))
        out.append(chunk(type: "IEND", data: []))
        try out.write(to: url)
    }
}
