import SwiftUI

/// Functional session UI: controls, live transcript, and status. Visual
/// design is deliberately plain here; the macOS 27 design pass replaces the
/// chrome without touching the data flow.
struct TranscriptSessionView: View {
    @Bindable var store: SessionStore
    let session: SessionController
    var overlay: SubtitleOverlayController?
    var exporter: (any TranscriptExporting)?
    /// Enables the main-screen language-pair/mode menu when provided.
    var capabilities: (any CapabilityChecking)?
    #if os(iOS)
    var broadcastMonitor: BroadcastStateMonitor?
    #endif

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
                if let capabilities {
                    LanguagePairMenu(store: store, capabilities: capabilities)
                }
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
        #if os(iOS)
        // The caption PiP window is started up front for system-audio
        // sessions (it keeps Luma alive in the background); take it down
        // symmetrically when the session ends — including the broadcast
        // ending on its own from Control Center.
        .onChange(of: store.sessionState) {
            if store.sessionState == .idle, store.inputKind == .systemAudio {
                overlay?.hide()
            }
        }
        #endif
    }

    // MARK: - Controls

    #if os(iOS)
    /// In-content control bar for iOS: an audio-source row (with the system
    /// broadcast control when capturing other apps' audio) above the transport
    /// and export actions.
    private var iosControlBar: some View {
        VStack(spacing: 10) {
            if let capabilities {
                HStack {
                    LanguagePairMenu(store: store, capabilities: capabilities)
                    Spacer()
                }
            }
            iosInputRow
            HStack(spacing: 16) {
                controlButtons
                    .labelStyle(.iconOnly)
                Spacer()
                // Labeled so the caption Picture in Picture control is
                // self-explanatory rather than a bare icon switch.
                overlayToggle
                    .toggleStyle(.button)
                exportMenu
                    .labelStyle(.iconOnly)
            }
            .font(.title3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Audio source selector. System Audio adds the ReplayKit broadcast button;
    /// the user enables Captions, starts the broadcast, picks Luma, then opens
    /// the app to caption.
    @ViewBuilder
    private var iosInputRow: some View {
        HStack(spacing: 12) {
            Picker("Input", selection: $store.inputKind) {
                Label("Microphone", systemImage: "microphone")
                    .tag(AudioInputKind.microphone)
                Label("System Audio", systemImage: "speaker.wave.2")
                    .tag(AudioInputKind.systemAudio)
            }
            .pickerStyle(.segmented)
            .disabled(store.sessionState != .idle)

            if store.inputKind == .systemAudio {
                // Backed so the system glyph reads as a tappable control.
                BroadcastPickerButton(size: 44)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: .circle)
            }
        }
        broadcastStatusBadge
    }

    /// Tells the user whether broadcast audio is actually flowing: a running
    /// session captures nothing until they start the system broadcast, and the
    /// red system status bar is easy to miss the absence of.
    @ViewBuilder
    private var broadcastStatusBadge: some View {
        if let broadcastMonitor, store.inputKind == .systemAudio {
            if broadcastMonitor.isBroadcastActive {
                Label("Capturing system audio", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if store.sessionState == .running {
                Label(
                    "Waiting for the screen broadcast — tap the record button",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if store.sessionState == .idle {
                Label(
                    "The record button starts a screen broadcast that captures audio only",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
    #endif

    #if os(macOS)
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
    #endif

    @ViewBuilder
    private var overlayToggle: some View {
        if let overlay {
            Toggle(
                "Captions", systemImage: "captions.bubble",
                isOn: Binding(
                    get: { overlay.isVisible },
                    set: { _ in overlay.toggle() }
                )
            )
            #if os(macOS)
            .help("Show or hide the floating caption window")
            #else
            .help("Show or hide captions in a Picture in Picture window")
            #endif
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
                #if os(iOS)
                // System-audio captions run while the user is in another app;
                // PiP both shows them and keeps Luma alive in the background, so
                // start it up front (it must be started from the foreground).
                if kind == .systemAudio { overlay?.show() }
                #endif
                Task {
                    await session.start(
                        languagePair: pair, inputKind: kind, translationMode: mode)
                    #if os(iOS)
                    // Preparation failed (state fell back to idle): take the
                    // optimistically started PiP window down again.
                    if kind == .systemAudio, store.sessionState != .running {
                        overlay?.hide()
                    }
                    #endif
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

    @ViewBuilder
    private var transcriptList: some View {
        if store.entries.isEmpty && store.volatileText == nil {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcriptScroll
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        #if os(iOS)
        if store.inputKind == .systemAudio, store.sessionState == .idle {
            // The broadcast flow is not discoverable on its own: nothing
            // happens until the user starts a system broadcast with Luma,
            // so the idle empty state doubles as the step-by-step guide.
            ContentUnavailableView {
                Label("No Captions Yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text(
                    "To caption another app's audio:\n1. Press Start.\n2. Tap the record button and start the screen broadcast with Luma Captions.\n3. Switch to the app you want to caption.\nOnly audio is captured — the screen is never recorded."
                )
            } actions: {
                BroadcastPickerButton(size: 52)
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: .circle)
            }
        } else {
            defaultEmptyState
        }
        #else
        defaultEmptyState
        #endif
    }

    private var defaultEmptyState: some View {
        // A blank scroll view on first launch reads as broken; tell the
        // user the app is ready (or already listening) instead.
        ContentUnavailableView {
            Label("No Captions Yet", systemImage: "captions.bubble")
        } description: {
            if store.sessionState == .idle {
                Text("Press Start to begin live captions.")
            } else {
                Text("Listening…")
            }
        }
    }

    private var transcriptScroll: some View {
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
            if store.sessionState == .running || store.sessionState == .paused {
                AudioLevelMeter(level: store.audioLevel)
            }
            Label(modelLabel, systemImage: modelSymbol)
            if let latency = store.latency,
                store.sessionState == .running || store.sessionState == .paused
            {
                // POSIX locale: a fixed format for a technical readout,
                // independent of the device region (the app language override
                // doesn't reach String(format:)). Milliseconds: at caption
                // latencies "0.1 s" carried almost no information.
                Label(
                    String(
                        format: "%.0f ms", locale: Locale(identifier: "en_US_POSIX"),
                        latency * 1000),
                    systemImage: "timer"
                )
                .monospacedDigit()
            }
            Spacer()
            if let message = store.errorMessage {
                // This is the one channel that says why a session stopped;
                // never truncate away the actionable part.
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(message)
            }
            // The language pair moved into the interactive main-screen menu;
            // keep the readout only when that menu is unavailable.
            if capabilities == nil {
                if let target = store.languagePair.translationTarget {
                    Text(
                        "\(store.languagePair.transcriptionLocale.identifier) → \(target.minimalIdentifier)"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(store.languagePair.transcriptionLocale.identifier) (transcribe only)")
                        .foregroundStyle(.secondary)
                }
            }
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
