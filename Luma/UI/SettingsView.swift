import SwiftUI

/// App settings: language pair and input source (General) and caption
/// surface appearance (Overlay).
struct SettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.system.rawValue

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
        #if os(macOS)
        .frame(width: 460, height: 400)
        #endif
        .navigationTitle("Settings")
        .appLanguage(appLanguageRaw)
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.system.rawValue

    @Environment(\.locale)
    private var displayLocale

    @State private var transcriptionLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []

    private var isSessionIdle: Bool { store.sessionState == .idle }

    var body: some View {
        Form {
            Section("App Language") {
                Picker("App Language", selection: $appLanguageRaw) {
                    Text("System").tag(AppLanguage.system.rawValue)
                    Text(verbatim: "English").tag(AppLanguage.english.rawValue)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Languages") {
                Picker("Transcribe", selection: transcriptionSelection) {
                    ForEach(displayedTranscriptionLocales, id: \.identifier) { locale in
                        Text(displayName(forLocale: locale)).tag(locale.identifier)
                    }
                }
                Picker("Translate to", selection: translationSelection) {
                    ForEach(displayedTranslationLanguages, id: \.maximalIdentifier) { language in
                        Text(displayName(forLanguage: language)).tag(language.maximalIdentifier)
                    }
                }
            }
            .disabled(!isSessionIdle)
            // macOS taps system audio via Core Audio; iOS via a ReplayKit
            // broadcast (started from the session controls).
            Section("Audio") {
                Picker("Input source", selection: $store.inputKind) {
                    Text("Microphone").tag(AudioInputKind.microphone)
                    Text("System Audio").tag(AudioInputKind.systemAudio)
                }
            }
            .disabled(!isSessionIdle)
            Section("Translation") {
                Picker("Mode", selection: $store.translationMode) {
                    Text("Fast").tag(TranslationMode.fast)
                    Text("Balanced").tag(TranslationMode.balanced)
                    Text("Accurate").tag(TranslationMode.accurate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(translationModeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Takes effect on the next start.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!isSessionIdle)
            if !isSessionIdle {
                Text("Stop the session to change languages or input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            transcriptionLocales = await capabilities.supportedTranscriptionLocales()
                .sorted { $0.identifier < $1.identifier }
            translationLanguages = await capabilities.supportedTranslationLanguages()
                .sorted { $0.maximalIdentifier < $1.maximalIdentifier }
        }
    }

    private var translationModeDescription: LocalizedStringKey {
        switch store.translationMode {
        case .fast:
            "Fast: re-translates the in-progress line as it updates, using the low-latency translation model. Most responsive; higher resource use."
        case .balanced:
            "Balanced: translates each finalized sentence with the low-latency translation model."
        case .accurate:
            "Accurate: translates finalized sentences with the high-fidelity model (Apple Intelligence when available). Best quality, more latency."
        }
    }

    /// The active pair may not be in the fetched lists (before they load, or for
    /// equivalents). Always include the current selection so the `Picker` has a
    /// matching tag on every render (otherwise SwiftUI logs an invalid-selection
    /// warning and shows undefined results).
    private var displayedTranscriptionLocales: [Locale] {
        let current = store.languagePair.transcriptionLocale
        if transcriptionLocales.contains(where: { $0.identifier == current.identifier }) {
            return transcriptionLocales
        }
        return [current] + transcriptionLocales
    }

    private var displayedTranslationLanguages: [Locale.Language] {
        let current = store.languagePair.translationTarget
        if translationLanguages.contains(where: { $0.maximalIdentifier == current.maximalIdentifier }) {
            return translationLanguages
        }
        return [current] + translationLanguages
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
        displayLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func displayName(forLanguage language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return displayLocale.localizedString(forIdentifier: identifier) ?? identifier
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
            #if os(macOS)
            // The surface style applies to the macOS floating panel; the iOS
            // caption surface is an opaque Picture in Picture window.
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
            #endif
        }
        .formStyle(.grouped)
    }
}
