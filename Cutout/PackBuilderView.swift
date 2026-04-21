import SwiftUI
import PhotosUI
import AVFoundation

struct PackBuilderView: View {
    @StateObject private var vm = PackBuilderViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var targetSlot: Int?
    @State private var shareURLs: [URL] = []
    @State private var showError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    packSizePicker
                    slotGrid
                    settingsCard
                    actionBlock
                    globalStatus
                }
                .padding()
            }
            .navigationTitle("Sticker Pack")
            .navigationBarTitleDisplayMode(.inline)
        }
        .photosPicker(isPresented: Binding(
            get: { targetSlot != nil },
            set: { if !$0 { targetSlot = nil; pickerItem = nil } }),
                      selection: $pickerItem,
                      matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: pickerItem) { _, item in
            guard let item, let idx = targetSlot else { return }
            Task { await handlePicked(item: item, slot: idx) }
        }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } })) {
            PackShareSheet(items: shareURLs)
        }
        .alert("Pack build failed",
               isPresented: Binding(get: { showError != nil },
                                    set: { if !$0 { showError = nil } }),
               presenting: showError) { _ in
            Button("OK", role: .cancel) { }
        } message: { Text($0) }
    }

    // MARK: - Pack size picker

    @ViewBuilder
    private var packSizePicker: some View {
        VStack(spacing: 4) {
            Picker("Pack Size", selection: Binding(
                get: { vm.packSize },
                set: { vm.setPackSize($0) })) {
                ForEach(PackSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            Text("LINE accepts 8, 16, or 24 animated stickers per pack.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Slot grid

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    @ViewBuilder
    private var slotGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(vm.slots.enumerated()), id: \.offset) { idx, state in
                SlotView(index: idx,
                         state: state,
                         isMainSource: idx == vm.mainSourceSlot,
                         onTap: { handleTap(slot: idx) },
                         onClear: { vm.clear(slot: idx) },
                         onMakeMain: { vm.mainSourceSlot = idx })
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Playback time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $vm.playbackSeconds) {
                    ForEach([1, 2, 3, 4], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Applies to every sticker in the pack.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Main / tab icon source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tap the star on a slot to use its middle frame for main.png (240×240) and tab.png (96×74). Currently slot \(vm.mainSourceSlot + 1).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .disabled(vm.isBatchRunning)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionBlock: some View {
        VStack(spacing: 10) {
            if vm.isBatchRunning {
                Button(role: .destructive) {
                    vm.cancelBatch()
                } label: {
                    Label("Cancel Batch", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    vm.startBatch()
                } label: {
                    Label("Process All Queued",
                          systemImage: "wand.and.sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.hasPendingWork)
            }

            Button {
                Task {
                    if let zip = await vm.exportPack() {
                        shareURLs = [zip]
                    } else if case .failed(let m) = vm.globalState {
                        showError = m
                    }
                }
            } label: {
                Label("Export LINE ZIP", systemImage: "archivebox.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!vm.allReady || vm.isBatchRunning)
        }
    }

    @ViewBuilder
    private var globalStatus: some View {
        switch vm.globalState {
        case .idle:
            EmptyView()
        case .batchRunning(let current, let total):
            VStack(spacing: 4) {
                ProgressView(value: Double(current), total: Double(total))
                    .tint(.accentColor)
                Text("Sticker \(current + 1) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .zipping:
            ProgressView("Packaging ZIP…")
        case .finished(let url, let count):
            VStack(spacing: 6) {
                Label("\(count)-sticker pack ready",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Slot tap handling

    private func handleTap(slot index: Int) {
        switch vm.slots[index] {
        case .empty:
            targetSlot = index
        case .sourceVideo, .failed:
            // Re-pick video for that slot
            targetSlot = index
        case .ready:
            // Tap-to-promote to main/tab source.
            vm.mainSourceSlot = index
        case .matting, .encoding:
            return
        }
    }

    private func handlePicked(item: PhotosPickerItem, slot: Int) async {
        defer {
            pickerItem = nil
            targetSlot = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            showError = "Couldn't load the chosen video."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack_\(slot)_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url)
            vm.assign(videoURL: url, to: slot)
        } catch {
            showError = "Couldn't save video: \(error.localizedDescription)"
        }
    }
}

// MARK: - Single slot view

private struct SlotView: View {
    let index: Int
    let state: SlotState
    let isMainSource: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onMakeMain: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            content
                .padding(6)

            HStack {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                if isMainSource {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(4)

            if state.hasVideo, !state.isProcessing {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Menu {
                            if case .ready = state {
                                Button("Make Main/Tab Source",
                                       systemImage: "star.fill",
                                       action: onMakeMain)
                            }
                            Button("Clear Slot",
                                   systemImage: "trash",
                                   role: .destructive, action: onClear)
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.body)
                                .symbolRenderingMode(.hierarchical)
                                .padding(4)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.title3)
                Text("Add").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sourceVideo:
            VStack(spacing: 4) {
                Image(systemName: "video.fill")
                Text("Queued").font(.caption2)
            }
            .foregroundStyle(.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .matting(let p):
            VStack(spacing: 4) {
                ProgressView(value: p).progressViewStyle(.circular)
                Text("\(Int(p * 100))%")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .encoding:
            VStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("APNG").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let a):
            AsyncImage(url: a.mainImageURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
        case .failed:
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Retry").font(.caption2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Dedicated share sheet so Cutout.Swift's ShareSheet (file-private) and
// ours don't conflict in the target.
struct PackShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                 context: Context) {}
}
