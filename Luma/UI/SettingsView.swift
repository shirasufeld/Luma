import SwiftUI

/// App settings: language pair and input source (General) and caption
/// surface appearance (Overlay).
struct SettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(store: store, capabilities: capabilities)
            }
            Tab("Appearance", systemImage: "paintpalette") {
                AppearanceSettingsView()
            }
            Tab("Overlay", systemImage: "captions.bubble") {
                OverlaySettingsView()
            }
        }
        .frame(width: 460, height: 400)
        .navigationTitle("Settings")
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    @State private var transcriptionLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []

    private var isSessionIdle: Bool { store.sessionState == .idle }

    var body: some View {
        Form {
            Section("Languages") {
                Picker("Transcribe", selection: transcriptionSelection) {
                    ForEach(transcriptionLocales, id: \.identifier) { locale in
                        Text(displayName(forLocale: locale)).tag(locale.identifier)
                    }
                }
                Picker("Translate to", selection: translationSelection) {
                    ForEach(translationLanguages, id: \.maximalIdentifier) { language in
                        Text(displayName(forLanguage: language)).tag(language.maximalIdentifier)
                    }
                }
            }
            Section("Audio") {
                Picker("Input source", selection: $store.inputKind) {
                    Text("Microphone").tag(AudioInputKind.microphone)
                    Text("System Audio").tag(AudioInputKind.systemAudio)
                }
            }
            Section("Translation") {
                Picker("Mode", selection: $store.translationMode) {
                    Text("Accurate (slower)").tag(TranslationMode.accurate)
                    Text("Realtime (faster)").tag(TranslationMode.realtime)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text("Accurate favors sentence quality; Realtime favors lower latency. Takes effect on the next start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !isSessionIdle {
                Text("Stop the session to change languages or input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!isSessionIdle)
        .task {
            transcriptionLocales = await capabilities.supportedTranscriptionLocales()
                .sorted { $0.identifier < $1.identifier }
            translationLanguages = await capabilities.supportedTranslationLanguages()
                .sorted { $0.maximalIdentifier < $1.maximalIdentifier }
            ensureCurrentValuesAreListed()
        }
    }

    /// The active pair may not be in the fetched lists (e.g. before lists
    /// load, or for equivalents); keep them selectable.
    private func ensureCurrentValuesAreListed() {
        let currentLocale = store.languagePair.transcriptionLocale
        if !transcriptionLocales.contains(where: { $0.identifier == currentLocale.identifier }) {
            transcriptionLocales.insert(currentLocale, at: 0)
        }
        let currentTarget = store.languagePair.translationTarget
        if !translationLanguages.contains(where: {
            $0.maximalIdentifier == currentTarget.maximalIdentifier
        }) {
            translationLanguages.insert(currentTarget, at: 0)
        }
    }

    private var transcriptionSelection: Binding<String> {
        Binding {
            store.languagePair.transcriptionLocale.identifier
        } set: { identifier in
            store.languagePair.transcriptionLocale = Locale(identifier: identifier)
        }
    }

    private var translationSelection: Binding<String> {
        Binding {
            store.languagePair.translationTarget.maximalIdentifier
        } set: { identifier in
            store.languagePair.translationTarget = Locale.Language(identifier: identifier)
        }
    }

    private func displayName(forLocale locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func displayName(forLanguage language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AppearanceSettingsKey.transcriptFontSize)
    private var transcriptFontSize: Double = AppearanceSettingsKey.defaultTranscriptFontSize
    @AppStorage(AppearanceSettingsKey.accentHex)
    private var accentHex = ""

    var body: some View {
        Form {
            Section("Transcript Text") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $transcriptFontSize, in: 11...24, step: 1) {
                            Text("Size")
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Text("\(Int(transcriptFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Sample transcript line")
                    .font(.system(size: transcriptFontSize))
            }
            Section("Accent Color") {
                LabeledContent("Translation highlight") {
                    ColorPicker(
                        "Translation highlight", selection: accentBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                Text("Sample translated line")
                    .font(.system(size: transcriptFontSize))
                    .foregroundStyle(accentBinding.wrappedValue)
                Button("Use System Accent") {
                    accentHex = ""
                }
                .disabled(accentHex.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var accentBinding: Binding<Color> {
        Binding {
            Color(hexString: accentHex) ?? .accentColor
        } set: { newColor in
            accentHex = newColor.hexString ?? ""
        }
    }
}

private struct OverlaySettingsView: View {
    @AppStorage(OverlaySettingsKey.fontSize)
    private var fontSize: Double = OverlaySettingsKey.defaultFontSize
    @AppStorage(OverlaySettingsKey.surface)
    private var surfaceRawValue: String = OverlaySurfaceStyle.liquidGlass.rawValue
    @AppStorage(OverlaySettingsKey.showOriginal)
    private var showOriginal = true
    @AppStorage(OverlaySettingsKey.showTranslation)
    private var showTranslation = true

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Size") {
                    Slider(value: $fontSize, in: 16...48, step: 1) {
                        Text("Size")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Toggle("Show original", isOn: $showOriginal)
                Toggle("Show translation", isOn: $showTranslation)
            }
            Section("Surface") {
                Picker("Background", selection: $surfaceRawValue) {
                    ForEach(OverlaySurfaceStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if reduceTransparency {
                    Text("Reduce Transparency is on; the overlay uses a solid background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
