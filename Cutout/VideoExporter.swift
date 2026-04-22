import Foundation
import AVFoundation
import Photos
import UIKit

/// Rotate a landscape rendered MatAnyone output back to portrait (if the
/// source was portrait) and save into the user's Photos library, or
/// return a URL for sharing.
enum VideoExporter {

    enum ExportError: LocalizedError {
        case exportFailed(String)
        case photosDenied

        var errorDescription: String? {
            switch self {
            case .exportFailed(let m): return "Export failed: \(m)"
            case .photosDenied:        return "Photos access was denied."
            }
        }
    }

    /// Writes a portrait-oriented `.mov` (transparent HEVC) next to the
    /// input landscape file. If the source was already landscape, the
    /// input URL is returned unchanged.
    static func orientOutput(landscapeURL: URL,
                             sourceOrientation: CGImagePropertyOrientation) async throws -> URL {
        guard needsRotation(sourceOrientation: sourceOrientation) else {
            return landscapeURL
        }
        let asset = AVURLAsset(url: landscapeURL)
        let exportPreset = AVAssetExportPresetHEVCHighestQualityWithAlpha
        guard let exporter = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            throw ExportError.exportFailed("no export session")
        }
        let composition = AVMutableVideoComposition()
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        composition.renderSize = CGSize(width: naturalSize.height, height: naturalSize.width)

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // `CutoutPipeline.landscapeCanvas` rotates portrait source → landscape
        // with a 90° CW step (`.oriented(.right)`). Undo that with a 90° CCW
        // rotation (video composition coords are Y-up, so +π/2 is CCW). The
        // translation recenters the rotated frame inside the renderSize.
        let rotate = CGAffineTransform(rotationAngle: .pi / 2)
            .concatenating(CGAffineTransform(translationX: naturalSize.height, y: 0))
        layerInstr.setTransform(rotate, at: .zero)
        instr.layerInstructions = [layerInstr]
        composition.instructions = [instr]
        exporter.videoComposition = composition

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutout_portrait_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outURL)
        exporter.outputURL = outURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        await exporter.export()
        if let e = exporter.error {
            throw ExportError.exportFailed(e.localizedDescription)
        }
        return outURL
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// Save a GIF (or any non-video image file) to Photos. iOS 17 Messages
    /// lets users long-press a saved GIF inside the keyboard and tap
    /// "Add Sticker" → the GIF becomes a reusable animated sticker.
    static func saveImageToPhotos(_ url: URL) async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    private static func needsRotation(sourceOrientation: CGImagePropertyOrientation) -> Bool {
        switch sourceOrientation {
        case .right, .left, .rightMirrored, .leftMirrored: return true
        default: return false
        }
    }
}
