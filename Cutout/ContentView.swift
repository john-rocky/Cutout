import SwiftUI
import AVKit
import PhotosUI

struct ContentView: View {
    @StateObject private var viewModel = ProcessingViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedURL: URL?
    @State private var shareURL: URL?
    @State private var showGIFShare = false
    @State private var showGIFError: String?
    @State private var savedToPhotos = false

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
        .alert("GIF export failed",
               isPresented: Binding(get: { showGIFError != nil },
                                    set: { if !$0 { showGIFError = nil } }),
               presenting: showGIFError) { _ in
            Button("OK", role: .cancel) { }
        } message: { text in Text(text) }
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
                Text("Pick a short video (≤ 10 s recommended)\nto cut out the subject.")
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
                HStack(spacing: 10) {
                    Button {
                        shareURL = portraitURL
                    } label: {
                        Label("Share Video", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            do {
                                let gif = try await GIFExporter.export(
                                    transparentHEVC: portraitURL)
                                shareURL = gif
                                showGIFShare = true
                            } catch {
                                showGIFError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Export GIF", systemImage: "photo.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

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
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil; showGIFShare = false } })) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
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
