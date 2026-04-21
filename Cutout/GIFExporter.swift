import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics
import CoreImage

/// Render the transparent-HEVC output to an animated GIF for LINE /
/// iMessage / chat sharing. GIF alpha is 1-bit only — we threshold at
/// 0.5 which is fine for LINE stickers (LINE specs 320×270 max).
enum GIFExporter {

    enum ExportError: LocalizedError {
        case decoderFailed(String)
        case encoderFailed(String)

        var errorDescription: String? {
            switch self {
            case .decoderFailed(let m): return "Couldn't read rendered video: \(m)"
            case .encoderFailed(let m): return "GIF encoder failed: \(m)"
            }
        }
    }

    /// `maxEdge` caps the longer side (LINE stickers max 320, iMessage ~400).
    static func export(transparentHEVC url: URL,
                       maxEdge: Int = 320,
                       framesPerSecond: Int = 15) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.decoderFailed("no video track")
        }
        let nominalSize = try await track.load(.naturalSize)
        let sourceFps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration)
        let totalFrames = max(1, Int((duration.seconds * sourceFps).rounded()))
        let hop = max(1, Int((sourceFps / Double(framesPerSecond)).rounded()))
        let step = 1.0 / Double(framesPerSecond)

        // Reader yielding BGRA with alpha preserved.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.decoderFailed(reader.error?.localizedDescription ?? "startReading")
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutout_\(UUID().uuidString).gif")
        try? FileManager.default.removeItem(at: outURL)

        let destType: CFString
        if #available(iOS 14.0, *) {
            destType = UTType.gif.identifier as CFString
        } else {
            destType = kUTTypeGIF
        }
        let frameCountHint = max(1, totalFrames / hop)
        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, destType, frameCountHint, nil) else {
            throw ExportError.encoderFailed("CGImageDestinationCreateWithURL")
        }

        let scale = Double(maxEdge) / Double(max(nominalSize.width, nominalSize.height))
        let targetW = Int(nominalSize.width * CGFloat(min(1.0, scale)))
        let targetH = Int(nominalSize.height * CGFloat(min(1.0, scale)))
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        var frameIndex = 0
        var emitted = 0
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let pb = CMSampleBufferGetImageBuffer(sample) else { break }
            defer { frameIndex += 1 }
            if frameIndex % hop != 0 { continue }

            let ci = CIImage(cvPixelBuffer: pb)
            let sx = Double(targetW) / Double(ci.extent.width)
            let sy = Double(targetH) / Double(ci.extent.height)
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(sx),
                                                              y: CGFloat(sy)))
            guard let cg = ciContext.createCGImage(scaled,
                from: CGRect(x: 0, y: 0, width: targetW, height: targetH)) else { continue }

            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: step,
                    kCGImagePropertyGIFUnclampedDelayTime as String: step
                ]
            ]
            CGImageDestinationAddImage(dest, cg, frameProperties as CFDictionary)
            emitted += 1
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
                kCGImagePropertyGIFHasGlobalColorMap as String: false
            ]
        ]
        CGImageDestinationSetProperties(dest, gifProperties as CFDictionary)

        if !CGImageDestinationFinalize(dest) {
            throw ExportError.encoderFailed("finalize")
        }
        if emitted == 0 {
            throw ExportError.encoderFailed("no frames written")
        }
        return outURL
    }
}
