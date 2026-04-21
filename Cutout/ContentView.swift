import SwiftUI
import AVKit
import PhotosUI

struct ContentView: View {
    @StateObject private var viewModel = ProcessingViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedURL: URL?
    @State private var shareURLs: [URL] = []
    @State private var showGIFError: String?
    @State private var showLINESheet = false
    @State private var lineSeconds: Int = 2
    @State private var lineExportState: LINEExportState = .idle
    @State private var savedToPhotos = false

    enum LINEExportState: Equatable {
        case idle
        case exporting
        case finished(apng: URL, main: URL, tab: URL, bytes: Int, dims: String, frames: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)

                statusBar
                    .padding(.horizontal)

                actionButtons
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            }
            .navigationTitle("Cutout")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .onChange(of: pickerItem) { _, new in
            guard let new else { return }
            Task { await loadPicked(new) }
        }
        .alert("Export failed",
               isPresented: Binding(get: { showGIFError != nil },
                                    set: { if !$0 { showGIFError = nil } }),
               presenting: showGIFError) { _ in
            Button("OK", role: .cancel) { }
        } message: { text in Text(text) }
        .sheet(isPresented: $showLINESheet) { lineExportSheet }
    }

    // MARK: - Preview area

    @ViewBuilder
    private var previewArea: some View {
        if case .finished(_, let portraitURL, _, _) = viewModel.state {
            CheckerboardPreview(url: portraitURL)
        } else if let pickedURL {
            VideoPlayer(player: AVPlayer(url: pickedURL))
        } else {
            VStack(spacing: 16) {
                Image(systemName: "scissors.badge.ellipsis")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Animated stickers from any video")
                    .font(.headline)
                Text("Pick a short clip (≤ 10 s). The app cuts out\nthe subject with a transparent background —\nready for iMessage, LINE, Discord, Reels.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.tertiarySystemBackground))
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            Text(viewModel.statusText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if isBusy {
                ProgressView(value: viewModel.progressFraction)
                    .tint(.accentColor)
            }
        }
    }

    private var isBusy: Bool {
        switch viewModel.state {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            switch viewModel.state {
            case .finished(_, let portraitURL, _, _):
                Button {
                    lineExportState = .idle
                    showLINESheet = true
                } label: {
                    Label("Export as LINE Sticker", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button {
                        shareURLs = [portraitURL]
                    } label: {
                        Label("Share Video", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button {
                            Task { await exportGIF(sourceURL: portraitURL, mode: .share) }
                        } label: {
                            Label("Share GIF", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await exportGIF(sourceURL: portraitURL, mode: .saveToPhotos) }
                        } label: {
                            Label("Save GIF to Photos",
                                  systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("GIF for Messages", systemImage: "photo.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.bordered)
                }

                Text("Save to Photos, then long-press the GIF inside Messages → **Add Sticker** to make it a reusable animated sticker.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            do {
                                try await VideoExporter.saveToPhotos(portraitURL)
                                savedToPhotos = true
                            } catch {
                                showGIFError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(savedToPhotos ? "Saved" : "Save to Photos",
                              systemImage: savedToPhotos ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(savedToPhotos)

                    Button {
                        viewModel.reset()
                        pickedURL = nil
                        pickerItem = nil
                        savedToPhotos = false
                    } label: {
                        Label("New", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button {
                    viewModel.reset()
                    pickedURL = nil
                    pickerItem = nil
                } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

            default:
                PhotosPicker(selection: $pickerItem,
                             matching: .videos,
                             preferredItemEncoding: .current) {
                    Label(pickedURL == nil ? "Pick Video" : "Pick Different Video",
                          systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if pickedURL != nil {
                    Button {
                        if let url = pickedURL { viewModel.process(url: url) }
                    } label: {
                        Label("Cut Out Subject", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } })) {
            ShareSheet(items: shareURLs)
        }
    }

    // MARK: - LINE export sheet

    @ViewBuilder
    private var lineExportSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch lineExportState {
                case .idle:
                    lineExportForm
                case .exporting:
                    ProgressView("Building APNG…")
                        .padding()
                case .finished(let apng, let main, let tab, let bytes, let dims, let frames):
                    lineExportResult(apng: apng, main: main, tab: tab,
                                     bytes: bytes, dims: dims, frames: frames)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .font(.callout)
                        Button("Close") { showLINESheet = false }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                }
                Spacer()
            }
            .navigationTitle("LINE Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showLINESheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var lineExportForm: some View {
        Form {
            Section {
                Picker("Playback", selection: $lineSeconds) {
                    ForEach([1, 2, 3, 4], id: \.self) { s in
                        Text("\(s) s").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Playback time")
            } footer: {
                Text("LINE accepts 1, 2, 3 or 4 seconds only. The clip is resampled evenly across the full source.")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Canvas auto-fits 320×270", systemImage: "rectangle.center.inset.filled")
                    Label("15 frames APNG, 1 loop", systemImage: "film.stack")
                    Label("≤ 1 MB checked", systemImage: "scalemass")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }

        Button {
            Task { await runLINEExport() }
        } label: {
            Label("Build APNG + Main + Tab", systemImage: "wand.and.sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func lineExportResult(apng: URL, main: URL, tab: URL,
                                   bytes: Int, dims: String, frames: Int) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Label("APNG sticker ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("\(dims) · \(frames) frames · \(bytes / 1024) KB")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    shareURLs = [apng, main, tab]
                    showLINESheet = false
                } label: {
                    Label("Share 3 Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    shareURLs = [apng]
                    showLINESheet = false
                } label: {
                    Label("Share APNG Only", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("""
            Combine 8, 16, or 24 APNGs into a ZIP to submit to LINE \
            Creators Market. Main image = 240×240, tab icon = 96×74 — \
            generated from the middle frame.
            """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - GIF helpers

    enum GIFExportMode { case share, saveToPhotos }

    private func exportGIF(sourceURL: URL, mode: GIFExportMode) async {
        do {
            let gifURL = try await GIFExporter.export(transparentHEVC: sourceURL)
            switch mode {
            case .share:
                shareURLs = [gifURL]
            case .saveToPhotos:
                try await VideoExporter.saveImageToPhotos(gifURL)
                savedToPhotos = true
            }
        } catch {
            showGIFError = error.localizedDescription
        }
    }

    private func runLINEExport() async {
        guard case .finished(_, let url, _, _) = viewModel.state else { return }
        lineExportState = .exporting
        do {
            let out = try await APNGExporter.export(
                from: url,
                params: APNGExporter.Params(playbackSeconds: lineSeconds,
                                            frameCount: 15,
                                            loops: 1))
            lineExportState = .finished(
                apng: out.apngURL,
                main: out.mainImageURL,
                tab: out.tabImageURL,
                bytes: out.fileBytes,
                dims: "\(out.dimensions.width)×\(out.dimensions.height)",
                frames: out.frameCount)
        } catch {
            lineExportState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Photo picker → temp file

    private func loadPicked(_ item: PhotosPickerItem) async {
        viewModel.reset()
        savedToPhotos = false
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked_\(UUID().uuidString).mov")
        try? data.write(to: url)
        pickedURL = url
    }
}

// MARK: - Checkerboard overlay for transparency preview

private struct CheckerboardPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let tile: CGFloat = 16
                let cols = Int(ceil(size.width / tile))
                let rows = Int(ceil(size.height / tile))
                for r in 0..<rows {
                    for c in 0..<cols {
                        let light = (r + c) % 2 == 0
                        ctx.fill(Path(CGRect(x: CGFloat(c) * tile,
                                              y: CGFloat(r) * tile,
                                              width: tile, height: tile)),
                                 with: .color(light ? Color(.systemGray6)
                                                    : Color(.systemGray4)))
                    }
                }
            }
            if let player {
                VideoPlayer(player: player)
                    .background(Color.clear)
                    .onAppear {
                        player.isMuted = true
                        player.play()
                        NotificationCenter.default.addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: player.currentItem, queue: .main) { _ in
                                player.seek(to: .zero)
                                player.play()
                            }
                    }
            }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause(); player = nil }
    }
}

// MARK: - UIKit share sheet bridge

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                 context: Context) {}
}
