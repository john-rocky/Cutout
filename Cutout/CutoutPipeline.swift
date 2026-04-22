import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMLZoo
import UIKit

/// Input video → per-frame alpha matte → transparent-HEVC or animated-GIF.
///
/// MatAnyone is locked to 768×432 landscape, so portrait sources get
/// rotated to landscape for inference and rotated back at export. The
/// output resolution matches that landscape canvas; callers can rotate
/// the exported file back into portrait before sharing.
actor CutoutPipeline {

    enum PipelineError: LocalizedError {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        case firstFrameUnavailable
        case maskEmpty

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:            return "Video has no visual track."
            case .readerFailed(let m):     return "Reader failed: \(m)"
            case .writerFailed(let m):     return "Writer failed: \(m)"
            case .firstFrameUnavailable:   return "Could not read the first frame."
            case .maskEmpty:
                return "Couldn't find a subject. Try a clip with a clearer subject in the first frame."
            }
        }
    }

    struct Progress: Sendable {
        enum Stage: Sendable, Equatable {
            case preparing
            case firstFrameMask
            case processing(frame: Int, total: Int)
            case encoding
            case done
        }
        let stage: Stage
        let fraction: Double
    }

    struct Output: Sendable {
        let mp4URL: URL               // landscape-oriented render
        let canvasSize: CGSize        // 768×432
        let sourceOrientation: CGImagePropertyOrientation
        let frameCount: Int
    }

    /// Run the full pipeline on `videoURL`. `onProgress` is called on an
    /// unspecified queue and may fire frequently.
    func run(videoURL: URL,
             onProgress: @escaping @Sendable (Progress) -> Void) async throws -> Output {
        onProgress(Progress(stage: .preparing, fraction: 0))

        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }

        let nominalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = nominalSize.applying(transform)
        let displayW = abs(displaySize.width)
        let displayH = abs(displaySize.height)
        let isPortrait = displayH > displayW
        let exifOrientation = Self.exifOrientation(from: transform)

        let canvasW = VideoMattingSession.frameWidth   // 768
        let canvasH = VideoMattingSession.frameHeight  // 432

        let nominalFps = try await track.load(.nominalFrameRate)
        let sourceFps = max(1.0, Double(nominalFps == 0 ? 30 : nominalFps))
        // Decimate to ≤10 fps output. The app targets animated stickers
        // (LINE APNG / chat GIF), where 5-20 frames over 1-4 s is the
        // format ceiling. 10 fps gives a ~100 ms inference gap — well
        // inside MatAnyone's temporal-attention comfort zone — and lines
        // up with LINE's max density (20-frame × 2 s sticker = exactly
        // 10 fps, no further subsampling). Going below ~5 fps starts to
        // drag the matte on fast motion.
        let targetFps: Double = 10.0
        let frameStep = max(1, Int((sourceFps / targetFps).rounded()))
        let outputFps = sourceFps / Double(frameStep)
        let duration = try await asset.load(.duration)
        let totalSourceFrames = max(1, Int((duration.seconds * sourceFps).rounded()))
        let totalOutputFrames = max(1, (totalSourceFrames + frameStep - 1) / frameStep)

        // Set up reader.
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw PipelineError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        // Pull the first frame as CGImage (in display orientation).
        guard let firstSample = readerOutput.copyNextSampleBuffer(),
              let firstPixelBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw PipelineError.firstFrameUnavailable
        }
        let firstFrame = try landscapeCanvas(from: firstPixelBuffer,
                                             exif: exifOrientation,
                                             isPortrait: isPortrait,
                                             canvasW: canvasW, canvasH: canvasH)

        onProgress(Progress(stage: .firstFrameMask, fraction: 0.05))

        // Mask pipeline: person → salient fallback.
        let maskResult = try await MaskPipeline.generate(
            from: firstFrame,
            targetSize: CGSize(width: canvasW, height: canvasH))

        // Open a MatAnyone session (SDK downloads models if needed).
        let session = try await VideoMattingSession(
            firstFrame: firstFrame,
            firstFrameMask: maskResult.mask,
            computeUnits: .auto)

        // Writer (transparent HEVC with alpha).
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutout_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: canvasW,
            AVVideoHeightKey: canvasH,
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_Quality: 0.85
            ] as [String: Any]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        let pbAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvasW,
                kCVPixelBufferHeightKey as String: canvasH
            ])
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw PipelineError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Process the first frame (reuse the already-rotated CGImage).
        // `srcIndex` counts source frames pulled from the reader (including
        // skipped ones); `outIndex` counts frames actually fed to MatAnyone
        // and written to the output.
        var srcIndex = 0
        var outIndex = 0
        try await appendFrame(session: session,
                              frame: firstFrame,
                              index: outIndex,
                              fps: outputFps,
                              adaptor: pbAdaptor,
                              canvasW: canvasW, canvasH: canvasH)
        srcIndex += 1
        outIndex += 1
        onProgress(Progress(stage: .processing(frame: outIndex, total: totalOutputFrames),
                            fraction: Double(outIndex) / Double(totalOutputFrames)))

        // Walk remaining frames, decimating to `outputFps`.
        while reader.status == .reading {
            guard let sample = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { break }
            defer { srcIndex += 1 }
            if srcIndex % frameStep != 0 { continue }
            let frame = try landscapeCanvas(from: pixelBuffer,
                                            exif: exifOrientation,
                                            isPortrait: isPortrait,
                                            canvasW: canvasW, canvasH: canvasH)
            try await appendFrame(session: session,
                                  frame: frame,
                                  index: outIndex,
                                  fps: outputFps,
                                  adaptor: pbAdaptor,
                                  canvasW: canvasW, canvasH: canvasH)
            outIndex += 1
            onProgress(Progress(stage: .processing(frame: outIndex, total: totalOutputFrames),
                                fraction: Double(outIndex) / Double(totalOutputFrames)))
        }

        onProgress(Progress(stage: .encoding, fraction: 0.99))
        writerInput.markAsFinished()
        await writer.finishWriting()

        onProgress(Progress(stage: .done, fraction: 1.0))
        return Output(mp4URL: outURL,
                      canvasSize: CGSize(width: canvasW, height: canvasH),
                      sourceOrientation: exifOrientation,
                      frameCount: outIndex)
    }

    // MARK: - Per-frame inference + compositing

    private func appendFrame(session: VideoMattingSession,
                             frame: CGImage,
                             index: Int,
                             fps: Double,
                             adaptor: AVAssetWriterInputPixelBufferAdaptor,
                             canvasW: Int, canvasH: Int) async throws {
        let alpha = try await session.process(frame)
        let composited = try composite(frame: frame, alpha: alpha,
                                        canvasW: canvasW, canvasH: canvasH)
        // Wait for writer readiness (back-pressure).
        while !adaptor.assetWriterInput.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let pts = CMTime(value: Int64(index), timescale: CMTimeScale(fps.rounded()))
        adaptor.append(composited, withPresentationTime: pts)
    }

    private func composite(frame: CGImage, alpha: CGImage,
                           canvasW: Int, canvasH: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, canvasW, canvasH,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let buffer = pb else {
            throw PipelineError.writerFailed("CVPixelBufferCreate")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: canvasW, height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw PipelineError.writerFailed("CGContext")
        }
        ctx.setFillColor(UIColor.clear.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        // Draw frame masked by alpha.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH),
                 mask: alpha)
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.restoreGState()

        return buffer
    }

    // MARK: - Orientation + scaling

    private func landscapeCanvas(from pixelBuffer: CVPixelBuffer,
                                  exif: CGImagePropertyOrientation,
                                  isPortrait: Bool,
                                  canvasW: Int, canvasH: Int) throws -> CGImage {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(exif)
        if isPortrait {
            ci = ci.oriented(.right)  // portrait → landscape (90° CW)
        }
        let sx = CGFloat(canvasW) / ci.extent.width
        let sy = CGFloat(canvasH) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled,
            from: CGRect(x: 0, y: 0, width: canvasW, height: canvasH)) else {
            throw PipelineError.readerFailed("CIContext render")
        }
        return cg
    }

    private static func exifOrientation(from transform: CGAffineTransform)
        -> CGImagePropertyOrientation
    {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case ( 0,  1, -1,  0): return .right
        case ( 0, -1,  1,  0): return .left
        case (-1,  0,  0, -1): return .down
        default:                return .up
        }
    }
}

// MARK: - Video Toolbox compression property keys (avoid extra import)
private let kVTCompressionPropertyKey_Quality = "Quality" as CFString
