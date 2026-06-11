import SwiftUI

/// Functional session UI: controls, live transcript, and status. Visual
/// design is deliberately plain here; the macOS 27 design pass replaces the
/// chrome without touching the data flow.
struct TranscriptSessionView: View {
    @Bindable var store: SessionStore
    let session: SessionController
    var overlay: SubtitleOverlayController?
    var exporter: (any TranscriptExporting)?

    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            transcriptList
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Input", selection: $store.inputKind) {
                    Label("Microphone", systemImage: "microphone")
                        .tag(AudioInputKind.microphone)
                    Label("System Audio", systemImage: "speaker.wave.2")
                        .tag(AudioInputKind.systemAudio)
                }
                .pickerStyle(.segmented)
                .disabled(store.sessionState != .idle)

                controlButtons

                if let overlay {
                    Toggle(
                        "Overlay", systemImage: "captions.bubble",
                        isOn: Binding(
                            get: { overlay.isVisible },
                            set: { _ in overlay.toggle() }
                        )
                    )
                    .help("Show or hide the floating caption window")
                }

                if exporter != nil {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Plain Text…") { export(.text) }
                        Button("SRT Subtitles…") { export(.srt) }
                    }
                    .menuIndicator(.hidden)
                    .disabled(store.entries.isEmpty)
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        .alert(
            "Export Failed",
            isPresented: .init(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlButtons: some View {
        switch store.sessionState {
        case .idle:
            Button("Start", systemImage: "play.circle") {
                let pair = store.languagePair
                let kind = store.inputKind
                Task { await session.start(languagePair: pair, inputKind: kind) }
            }
        case .running:
            Button("Pause", systemImage: "pause.circle") {
                Task { await session.pause() }
            }
            stopButton
        case .paused:
            Button("Resume", systemImage: "play.circle") {
                Task { await session.resume() }
            }
            stopButton
        case .preparing, .stopping:
            ProgressView()
                .controlSize(.small)
        }

        Button("Clear", systemImage: "trash") {
            Task { await session.clearTranscript() }
        }
        .disabled(store.entries.isEmpty && store.volatileText == nil)
    }

    private func export(_ format: TranscriptExportFormat) {
        guard let exporter else { return }
        let entries = store.entries
        Task {
            do {
                _ = try await exporter.export(entries: entries, format: format)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.circle") {
            Task { await session.stop() }
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.entries) { entry in
                        entryRow(entry)
                    }
                    if let volatileText = store.volatileText {
                        Text(volatileText)
                            .foregroundStyle(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("volatile")
                    }
                }
                .padding()
            }
            .onChange(of: store.entries.count) {
                if let lastID = store.entries.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: store.volatileText) {
                if store.volatileText != nil {
                    proxy.scrollTo("volatile", anchor: .bottom)
                }
            }
        }
    }

    private func entryRow(_ entry: SubtitleEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.segment.plainText)
            switch entry.translation {
            case .translated(let translation):
                Text(translation)
                    .foregroundStyle(.tint)
            case .pending:
                Text("Translating…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .failed(let message):
                Text("Translation failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .unavailable:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(entry.id)
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(sessionLabel, systemImage: sessionSymbol)
            Label(modelLabel, systemImage: modelSymbol)
            if let latency = store.latency,
                store.sessionState == .running || store.sessionState == .paused
            {
                Label(String(format: "%.1f s", latency), systemImage: "timer")
                    .monospacedDigit()
            }
            Spacer()
            if let message = store.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Text(
                "\(store.languagePair.transcriptionLocale.identifier) → \(store.languagePair.translationTarget.minimalIdentifier)"
            )
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sessionLabel: String {
        switch store.sessionState {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .running: "Live"
        case .paused: "Paused"
        case .stopping: "Stopping"
        }
    }

    private var sessionSymbol: String {
        switch store.sessionState {
        case .running: "waveform"
        case .paused: "pause"
        default: "circle"
        }
    }

    private var modelSymbol: String {
        switch store.modelState {
        case nil, .checking: "magnifyingglass.circle"
        case .downloading: "arrow.down.circle"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var modelLabel: String {
        switch store.modelState {
        case nil: "Model: —"
        case .checking: "Model: checking"
        case .downloading(let progress):
            if let progress {
                "Model: downloading \(Int(progress * 100))%"
            } else {
                "Model: downloading"
            }
        case .ready: "Model: ready"
        case .failed: "Model: failed"
        }
    }
}
