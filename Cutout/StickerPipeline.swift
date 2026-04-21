import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMLZoo

/// Fast path tailored for LINE-sticker output. Instead of running
/// MatAnyone on every source frame (like `CutoutPipeline` does for its
/// transparent-HEVC deliverable), `StickerPipeline` samples **only the N
/// frames it needs for the APNG** — typically 15 — plus one pre-warm
/// frame for the session. 16 inferences per video, full stop.
///
/// Rough numbers on iPhone 13 (MatAnyone ≈ 400 ms / frame):
/// - `CutoutPipeline` for a 5 s 30 fps clip: 150 × 400 ms ≈ 60 s.
/// - `StickerPipeline` for the same clip: 16 × 400 ms ≈ 6.5 s.
///
/// Temporal coherence takes a small hit because the session is now fed
/// frames spaced ~300 ms apart instead of 33 ms apart, but for
/// 15-frame 2-second stickers the visual difference is negligible.
actor StickerPipeline {

    enum PipelineError: LocalizedError {
        case noVideoTrack
        case firstFrame
        case frameSample(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:     return "Source clip has no video track."
            case .firstFrame:       return "Couldn't read the first frame."
            case .frameSample(let m): return "Frame sampling failed: \(m)"
            }
        }
    }

    struct Progress: Sendable {
        enum Stage: Sendable, Equatable {
            case sampling(frame: Int, total: Int)
            case masking
            case matting(frame: Int, total: Int)
            case encoding
            case done
        }
        let stage: Stage
        let fraction: Double
    }

    struct Output: Sendable {
        let apngURL: URL
        let mainImageURL: URL
        let tabImageURL: URL
        let bytes: Int
        let width: Int
        let height: Int
        let frameCount: Int
    }

    /// Entry point. `playbackSeconds` ∈ {1, 2, 3, 4}. `frameCount` is the
    /// APNG frame count (5–20, LINE rule). Total MatAnyone inferences =
    /// `frameCount + 1` (init pre-warm + per-output process calls).
    func run(videoURL: URL,
             playbackSeconds: Int = 2,
             frameCount: Int = 15,
             loops: Int = 1,
             onProgress: @escaping @Sendable (Progress) -> Void) async throws -> Output {

        precondition([1, 2, 3, 4].contains(playbackSeconds),
                     "LINE allows 1, 2, 3, or 4 second playback only")
        let clampedN = max(5, min(20, frameCount))

        // 1. Asset metadata
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = natural.applying(transform)
        let displayW = abs(displaySize.width)
        let displayH = abs(displaySize.height)
        let isPortrait = displayH > displayW
        let duration = try await asset.load(.duration).seconds

        let canvasW = VideoMattingSession.frameWidth   // 768
        let canvasH = VideoMattingSession.frameHeight  // 432

        // 2. Extract N + 1 frames evenly. Index 0 is the pre-warm frame
        //    (seeds MatAnyone's ring buffer, NOT emitted in the APNG).
        //    Indices 1...N are the output frames.
        let sampleTimes: [CMTime] = (0...clampedN).map { i in
            let t = duration * Double(i) / Double(clampedN)
            return CMTime(seconds: t, preferredTimescale: 600)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // 2× the canvas keeps enough data for high-quality downscale.
        generator.maximumSize = CGSize(width: canvasW * 2, height: canvasH * 2)

        var landscapeFrames: [CGImage] = []
        landscapeFrames.reserveCapacity(clampedN + 1)
        for (i, time) in sampleTimes.enumerated() {
            onProgress(Progress(stage: .sampling(frame: i + 1, total: clampedN + 1),
                                fraction: Double(i) / Double(clampedN + 1)))
            let cg = try await Self.extractCGImage(from: generator, at: time)
            let landscape = try Self.rotateAndScale(
                cg,
                isPortrait: isPortrait,
                canvasW: canvasW, canvasH: canvasH)
            landscapeFrames.append(landscape)
        }

        // 3. First-frame mask (Vision PersonSeg → RMBG fallback).
        onProgress(Progress(stage: .masking, fraction: 0.15))
        let maskResult = try await MaskPipeline.generate(
            from: landscapeFrames[0],
            targetSize: CGSize(width: canvasW, height: canvasH))

        // 4. Seed MatAnyone with frame 0. Per-slot new session for clean
        //    ring buffer.
        let session = try await VideoMattingSession(
            firstFrame: landscapeFrames[0],
            firstFrameMask: maskResult.mask,
            computeUnits: .auto)

        // 5. Process output frames (indices 1…N).
        var alphaFrames: [CGImage] = []
        alphaFrames.reserveCapacity(clampedN)
        for i in 1...clampedN {
            onProgress(Progress(stage: .matting(frame: i, total: clampedN),
                                fraction: 0.2 + 0.75 * Double(i) / Double(clampedN)))
            let alpha = try await session.process(landscapeFrames[i])
            alphaFrames.append(alpha)
        }

        // 6. Target LINE dimensions.
        let (outW, outH) = APNGExporter.computeLINEDimensions(srcW: canvasW, srcH: canvasH)

        // 7. Compose each (frame, alpha) pair into straight-alpha RGBA at
        //    output resolution.
        onProgress(Progress(stage: .encoding, fraction: 0.96))
        var rgbaFrames: [[UInt8]] = []
        rgbaFrames.reserveCapacity(clampedN)
        for i in 0..<clampedN {
            let rgba = APNGExporter.composeSubjectRGBA(
                source: landscapeFrames[i + 1],
                alpha: alphaFrames[i],
                canvasW: outW, canvasH: outH,
                fitAspect: false)  // aspect matches so stretch == fit here
            rgbaFrames.append(rgba)
        }

        // 8. Encode + write APNG.
        let apngData = APNGExporter.encodeAnimatedAPNG(
            frames: rgbaFrames,
            width: outW, height: outH,
            playbackSeconds: playbackSeconds,
            loops: loops)
        if apngData.count > 1_000_000 {
            throw APNGExporter.APNGError.oversize(bytes: apngData.count)
        }

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let apngURL = outDir.appendingPathComponent("sticker.png")
        let mainURL = outDir.appendingPathComponent("main.png")
        let tabURL  = outDir.appendingPathComponent("tab.png")
        try apngData.write(to: apngURL)

        // 9. Main 240×240 + tab 96×74 from middle frame — aspect-fit with
        //    transparent padding so we never mask-out the subject.
        let midIndex = clampedN / 2
        let middleSource = landscapeFrames[midIndex + 1]
        let middleAlpha  = alphaFrames[midIndex]

        let mainRGBA = APNGExporter.composeSubjectRGBA(
            source: middleSource, alpha: middleAlpha,
            canvasW: 240, canvasH: 240, fitAspect: true)
        let tabRGBA = APNGExporter.composeSubjectRGBA(
            source: middleSource, alpha: middleAlpha,
            canvasW: 96, canvasH: 74, fitAspect: true)
        try APNGExporter.encodeStaticPNG(rgba: mainRGBA, width: 240, height: 240).write(to: mainURL)
        try APNGExporter.encodeStaticPNG(rgba: tabRGBA,  width:  96, height:  74).write(to: tabURL)

        onProgress(Progress(stage: .done, fraction: 1.0))

        return Output(apngURL: apngURL,
                      mainImageURL: mainURL,
                      tabImageURL: tabURL,
                      bytes: apngData.count,
                      width: outW, height: outH,
                      frameCount: clampedN)
    }

    // MARK: - Helpers

    private static func extractCGImage(from generator: AVAssetImageGenerator,
                                         at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, _, error in
                if let error {
                    cont.resume(throwing: PipelineError.frameSample(error.localizedDescription))
                    return
                }
                if let image {
                    cont.resume(returning: image); return
                }
                cont.resume(throwing: PipelineError.firstFrame)
            }
        }
    }

    private static func rotateAndScale(_ image: CGImage,
                                         isPortrait: Bool,
                                         canvasW: Int, canvasH: Int) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        if isPortrait {
            ci = ci.oriented(.right)  // portrait → landscape
        }
        let sx = CGFloat(canvasW) / ci.extent.width
        let sy = CGFloat(canvasH) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(
            scaled,
            from: CGRect(x: 0, y: 0, width: canvasW, height: canvasH)) else {
            throw PipelineError.frameSample("CIContext render")
        }
        return cg
    }
}
