import Foundation
import CoreGraphics

/// LINE Creators Market accepts 8, 16, or 24 animated stickers per pack.
public enum PackSize: Int, CaseIterable, Identifiable, Sendable {
    case eight = 8
    case sixteen = 16
    case twentyFour = 24

    public var id: Int { rawValue }
    public var title: String { "\(rawValue)" }
}

/// Generated artifacts for one finished sticker slot.
struct SlotArtifacts: Equatable {
    let apngURL: URL
    let mainImageURL: URL   // 240×240 static PNG, LINE main image candidate
    let tabImageURL: URL    // 96×74 static PNG, LINE tab icon candidate
    let bytes: Int
    let width: Int
    let height: Int
}

/// Per-slot state machine.
enum SlotState: Equatable {
    case empty
    case sourceVideo(URL)          // user picked but not yet processed
    case matting(Double)           // CutoutPipeline in progress (progress 0..1)
    case encoding                  // APNGExporter in progress
    case ready(SlotArtifacts)      // APNG + main + tab all on disk
    case failed(String)            // per-slot error message

    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var isEmpty: Bool { if case .empty = self { return true } else { return false } }
    var hasVideo: Bool {
        switch self {
        case .sourceVideo, .matting, .encoding, .ready, .failed: return true
        case .empty: return false
        }
    }
    var isProcessing: Bool {
        switch self { case .matting, .encoding: return true; default: return false }
    }
}
