import Foundation
import CoreMLZoo
import SwiftUI

@MainActor
final class ProcessingViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case downloadingModels(fraction: Double, label: String)
        case maskGen
        case matting(frame: Int, total: Int)
        case encoding
        case finished(landscapeURL: URL,
                       portraitURL: URL,
                       isPortrait: Bool,
                       frameCount: Int)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var progressFraction: Double = 0
    @Published var statusText: String = "Pick a video to start"

    private let pipeline = CutoutPipeline()

    func process(url: URL) {
        Task { await self.runPipeline(url: url) }
    }

    func reset() {
        state = .idle
        progressFraction = 0
        statusText = "Pick a video to start"
    }

    private func runPipeline(url: URL) async {
        // 1. Ensure MatAnyone mlpackages are on disk.
        do {
            let requiredIds = ["matanyone", "rmbg_1_4"]
            for modelId in requiredIds {
                let isInstalled = await CMZModelStore.shared.isInstalled(id: modelId)
                if isInstalled { continue }
                updateStatus("Downloading \(modelId)…", fraction: 0)
                for try await p in CMZModelStore.shared.download(id: modelId) {
                    let label = p.currentFile ?? modelId
                    self.state = .downloadingModels(fraction: p.fraction, label: label)
                    self.progressFraction = p.fraction
                    self.statusText = "Downloading \(label) \(Int(p.fraction * 100))%"
                }
            }
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
            return
        }

        // 2. Run pipeline.
        let output: CutoutPipeline.Output
        do {
            state = .maskGen
            statusText = "Finding subject…"
            output = try await pipeline.run(videoURL: url) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    switch progress.stage {
                    case .preparing:
                        self.state = .maskGen
                        self.statusText = "Preparing…"
                    case .firstFrameMask:
                        self.state = .maskGen
                        self.statusText = "Finding subject…"
                    case .processing(let frame, let total):
                        self.state = .matting(frame: frame, total: total)
                        self.statusText = "Matting frame \(frame) of \(total)"
                    case .encoding:
                        self.state = .encoding
                        self.statusText = "Encoding…"
                    case .done:
                        break
                    }
                    self.progressFraction = progress.fraction
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // 3. Rotate back to portrait if needed.
        statusText = "Finalizing…"
        let isPortrait = output.sourceOrientation == .right
                      || output.sourceOrientation == .left
        let finalURL: URL
        do {
            finalURL = try await VideoExporter.orientOutput(
                landscapeURL: output.mp4URL,
                sourceOrientation: output.sourceOrientation)
        } catch {
            finalURL = output.mp4URL
        }

        state = .finished(landscapeURL: output.mp4URL,
                          portraitURL: finalURL,
                          isPortrait: isPortrait,
                          frameCount: output.frameCount)
        statusText = "Done — \(output.frameCount) frames"
    }

    private func updateStatus(_ text: String, fraction: Double) {
        statusText = text
        progressFraction = fraction
    }
}
