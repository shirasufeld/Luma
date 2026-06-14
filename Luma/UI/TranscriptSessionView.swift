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

    @AppStorage(AppearanceSettingsKey.transcriptFontSize)
    private var transcriptFontSize: Double = AppearanceSettingsKey.defaultTranscriptFontSize

    var body: some View {
        VStack(spacing: 0) {
            transcriptList
            Divider()
            // macOS packs the controls into the window toolbar; on iOS the
            // bottom region belongs to the TabView, so the controls live in an
            // in-content bar above the status line instead.
            #if os(iOS)
            iosControlBar
            Divider()
            #endif
            statusBar
        }
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup {
                inputPicker
                controlButtons
                overlayToggle
                exportMenu
                // macOS opens the dedicated Settings scene; iOS presents
                // settings as a sheet from ContentView's navigation bar.
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        #endif
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

    #if os(iOS)
    /// In-content control bar for iOS: input picker on top, transport and
    /// export actions below.
    private var iosControlBar: some View {
        VStack(spacing: 10) {
            inputPicker
            HStack(spacing: 16) {
                controlButtons
                Spacer()
                overlayToggle
                exportMenu
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    #endif

    private var inputPicker: some View {
        Picker("Input", selection: $store.inputKind) {
            Label("Microphone", systemImage: "microphone")
                .tag(AudioInputKind.microphone)
            Label("System Audio", systemImage: "speaker.wave.2")
                .tag(AudioInputKind.systemAudio)
        }
        .pickerStyle(.segmented)
        .disabled(store.sessionState != .idle)
    }

    @ViewBuilder
    private var overlayToggle: some View {
        if let overlay {
            Toggle(
                "Overlay", systemImage: "captions.bubble",
                isOn: Binding(
                    get: { overlay.isVisible },
                    set: { _ in overlay.toggle() }
                )
            )
            .help("Show or hide the caption overlay")
        }
    }

    @ViewBuilder
    private var exportMenu: some View {
        if exporter != nil {
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Plain Text…") { export(.text) }
                Button("SRT Subtitles…") { export(.srt) }
            }
            .menuIndicator(.hidden)
            // Match the neutral monochrome of the other toolbar buttons
            // instead of the app accent.
            .tint(.primary)
            .disabled(store.entries.isEmpty)
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch store.sessionState {
        case .idle:
            Button("Start", systemImage: "play.circle") {
                let pair = store.languagePair
                let kind = store.inputKind
                let mode = store.translationMode
                Task {
                    await session.start(
                        languagePair: pair, inputKind: kind, translationMode: mode)
                }
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volatileText)
                                .font(.system(size: transcriptFontSize))
                                .foregroundStyle(.secondary)
                                .italic()
                            if let volatileTranslation = store.volatileTranslation {
                                Text(volatileTranslation)
                                    .font(.system(size: transcriptFontSize))
                                    .foregroundStyle(.tint.opacity(0.7))
                                    .italic()
                            }
                        }
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
                .font(.system(size: transcriptFontSize))
            switch entry.translation {
            case .translated(let translation):
                Text(translation)
                    .font(.system(size: transcriptFontSize))
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

    private var sessionLabel: LocalizedStringKey {
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

    private var modelLabel: LocalizedStringKey {
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
