import Foundation
import SwiftUI
import CoreMLZoo

@MainActor
final class PackBuilderViewModel: ObservableObject {

    enum GlobalState: Equatable {
        case idle
        case batchRunning(current: Int, total: Int)
        case zipping
        case finished(zipURL: URL, stickerCount: Int)
        case failed(String)
    }

    @Published var packSize: PackSize = .eight
    @Published var slots: [SlotState] = Array(repeating: .empty, count: 8)
    @Published var playbackSeconds: Int = 2
    @Published var mainSourceSlot: Int = 0
    @Published var globalState: GlobalState = .idle

    private let pipeline = StickerPipeline()
    private var batchTask: Task<Void, Never>?

    var hasPendingWork: Bool {
        slots.contains { if case .sourceVideo = $0 { return true } else { return false } }
    }

    var isBatchRunning: Bool {
        if case .batchRunning = globalState { return true } else { return false }
    }

    var allReady: Bool { !slots.isEmpty && slots.allSatisfy { $0.isReady } }

    // MARK: - Pack size changes

    func setPackSize(_ size: PackSize) {
        guard size != packSize else { return }
        let old = slots
        var next = Array(repeating: SlotState.empty, count: size.rawValue)
        for i in 0..<min(old.count, next.count) {
            next[i] = old[i]
        }
        slots = next
        packSize = size
        if mainSourceSlot >= next.count { mainSourceSlot = 0 }
    }

    // MARK: - Slot assignment

    func assign(videoURL: URL, to index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = .sourceVideo(videoURL)
    }

    func clear(slot index: Int) {
        guard slots.indices.contains(index) else { return }
        // Best-effort cleanup of on-disk artifacts.
        if case .ready(let a) = slots[index] {
            try? FileManager.default.removeItem(at: a.apngURL)
            try? FileManager.default.removeItem(at: a.mainImageURL)
            try? FileManager.default.removeItem(at: a.tabImageURL)
        }
        slots[index] = .empty
    }

    func retrySlot(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        // Only retry slots that failed — restore them to sourceVideo(url)
        // if we still have the URL cached somewhere. Simpler UX: ask the
        // user to re-pick the video.
        slots[index] = .empty
    }

    // MARK: - Batch processing

    func startBatch() {
        guard !isBatchRunning else { return }
        batchTask = Task { await runBatch() }
    }

    func cancelBatch() {
        batchTask?.cancel()
        batchTask = nil
        // Any slots stuck in .matting/.encoding go back to empty to allow retry.
        for i in slots.indices where slots[i].isProcessing {
            slots[i] = .empty
        }
        globalState = .idle
    }

    private func runBatch() async {
        // Collect the pending slot indices in order.
        let indicesToRun: [Int] = slots.enumerated().compactMap {
            if case .sourceVideo = $0.element { return $0.offset } else { return nil }
        }
        guard !indicesToRun.isEmpty else {
            globalState = .failed("Add at least one video first.")
            return
        }
        globalState = .batchRunning(current: 0, total: indicesToRun.count)

        // Ensure required mlpackages are on disk (triggered by first
        // slot's pipeline call anyway, but showing global progress first
        // is friendlier). Fire-and-forget.
        for modelId in ["matanyone", "rmbg_1_4"] {
            if await CMZModelStore.shared.isInstalled(id: modelId) { continue }
            do {
                for try await _ in CMZModelStore.shared.download(id: modelId) {}
            } catch {
                // Let per-slot processing surface the error; continue here.
            }
        }

        for (step, slotIndex) in indicesToRun.enumerated() {
            if Task.isCancelled { break }
            globalState = .batchRunning(current: step, total: indicesToRun.count)
            guard case .sourceVideo(let videoURL) = slots[slotIndex] else { continue }

            do {
                slots[slotIndex] = .matting(0)
                let out = try await pipeline.run(
                    videoURL: videoURL,
                    playbackSeconds: playbackSeconds,
                    frameCount: 15,
                    loops: 1
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        switch progress.stage {
                        case .sampling, .masking, .matting:
                            self.slots[slotIndex] = .matting(progress.fraction)
                        case .encoding:
                            self.slots[slotIndex] = .encoding
                        case .done:
                            break
                        }
                    }
                }
                if Task.isCancelled { break }

                slots[slotIndex] = .ready(SlotArtifacts(
                    apngURL: out.apngURL,
                    mainImageURL: out.mainImageURL,
                    tabImageURL: out.tabImageURL,
                    bytes: out.bytes,
                    width: out.width,
                    height: out.height))
            } catch {
                slots[slotIndex] = .failed(error.localizedDescription)
            }
        }

        if Task.isCancelled {
            globalState = .idle
        } else if slots.contains(where: { if case .failed = $0 { return true } else { return false } }) {
            globalState = .idle
        } else if allReady {
            globalState = .idle
        } else {
            globalState = .idle
        }
        batchTask = nil
    }

    // MARK: - Export ZIP

    func exportPack() async -> URL? {
        guard allReady else {
            globalState = .failed("Fill every slot first.")
            return nil
        }
        globalState = .zipping
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("linepack_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp,
                withIntermediateDirectories: true)

            var entries: [(name: String, url: URL)] = []

            // 01.png … NN.png for each animated sticker
            for (i, state) in slots.enumerated() {
                guard case .ready(let a) = state else { continue }
                let name = String(format: "%02d.png", i + 1)
                let dst = tmp.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: a.apngURL, to: dst)
                entries.append((name: name, url: dst))
            }

            // Main + tab from chosen slot
            guard case .ready(let mainArt) = slots[mainSourceSlot] else {
                globalState = .failed("Main image slot isn't ready.")
                return nil
            }
            let mainDst = tmp.appendingPathComponent("main.png")
            let tabDst  = tmp.appendingPathComponent("tab.png")
            try? FileManager.default.removeItem(at: mainDst)
            try? FileManager.default.removeItem(at: tabDst)
            try FileManager.default.copyItem(at: mainArt.mainImageURL, to: mainDst)
            try FileManager.default.copyItem(at: mainArt.tabImageURL,  to: tabDst)
            entries.append((name: "main.png", url: mainDst))
            entries.append((name: "tab.png",  url: tabDst))

            let zipURL = tmp.appendingPathComponent("line_pack_\(packSize.rawValue).zip")
            try ZipPackager.write(files: entries, to: zipURL)

            // Validate total size ≤ 60 MB (LINE limit)
            let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
            if size > 60_000_000 {
                globalState = .failed("Pack exceeds LINE's 60 MB ZIP limit. Try shorter playback times.")
                return nil
            }

            globalState = .finished(zipURL: zipURL, stickerCount: packSize.rawValue)
            return zipURL
        } catch {
            globalState = .failed(error.localizedDescription)
            return nil
        }
    }
}
