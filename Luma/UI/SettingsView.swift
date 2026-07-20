import SwiftUI

/// App settings: language pair and input source (General), caption surface
/// appearance (Overlay), and the read-only Diagnostics panel.
struct SettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking
    #if os(iOS)
    /// Live broadcast state for the Diagnostics system-audio row.
    var broadcastMonitor: BroadcastStateMonitor? = nil
    #endif

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.systemValue

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
            Tab("Diagnostics", systemImage: "checklist") {
                #if os(iOS)
                CapabilityPanel(
                    capabilities: capabilities,
                    languagePair: store.languagePair,
                    broadcastMonitor: broadcastMonitor)
                #else
                CapabilityPanel(
                    capabilities: capabilities,
                    languagePair: store.languagePair)
                #endif
            }
        }
        #if os(macOS)
        // Sized for the widest tab (Diagnostics' outcome rows).
        .frame(width: 500, height: 480)
        #endif
        .navigationTitle("Settings")
        .appLanguage(appLanguageRaw)
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.systemValue

    @Environment(\.locale)
    private var displayLocale

    @State private var transcriptionLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []

    @AppStorage(IntelligenceSettingsKey.proofreadTranscription)
    private var proofreadTranscription = true
    @AppStorage(IntelligenceSettingsKey.proofreadTranslation)
    private var proofreadTranslation = true

    private var isSessionIdle: Bool { store.sessionState == .idle }

    var body: some View {
        Form {
            Section("App Language") {
                Picker("App Language", selection: languageModeSelection) {
                    Text("System").tag(AppLanguage.systemValue)
                    Text("Custom").tag(customModeTag)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if appLanguageRaw != AppLanguage.systemValue {
                    Picker("Language", selection: $appLanguageRaw) {
                        ForEach(AppLanguage.available, id: \.id) { entry in
                            // Endonyms stay in their own script, never localized.
                            Text(verbatim: entry.endonym).tag(entry.id)
                        }
                    }
                }
            }
            Section("Languages") {
                Picker("Transcribe", selection: transcriptionSelection) {
                    ForEach(displayedTranscriptionLocales, id: \.identifier) { locale in
                        Text(displayName(forLocale: locale)).tag(locale.identifier)
                    }
                }
                Picker("Translate to", selection: translationSelection) {
                    Text("None (transcription only)").tag(LanguagePair.noneTargetValue)
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
                    Text("Real-time").tag(TranslationMode.fast)
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
            Section {
                Toggle("Proofread transcription", isOn: $proofreadTranscription)
                Toggle("Proofread translation", isOn: $proofreadTranslation)
                Text(
                    "Smart Proofread fixes recognition and translation errors on device once sentences are finalized."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                // Brand name; never localized.
                Text(verbatim: "Apple Intelligence")
            }
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

    private let customModeTag = "custom"

    /// System vs Custom. Switching to Custom starts from the system language
    /// when the app ships it; the dropdown then picks the concrete language.
    private var languageModeSelection: Binding<String> {
        Binding {
            appLanguageRaw == AppLanguage.systemValue ? AppLanguage.systemValue : customModeTag
        } set: { mode in
            if mode == AppLanguage.systemValue {
                appLanguageRaw = AppLanguage.systemValue
            } else if appLanguageRaw == AppLanguage.systemValue {
                appLanguageRaw = AppLanguage.defaultCustomID()
            }
        }
    }

    private var translationModeDescription: LocalizedStringKey {
        switch store.translationMode {
        case .fast:
            "Real-time: also translates the line being spoken as it updates, using the low-latency translation model. Most responsive; higher resource use."
        case .accurate:
            "Accurate: translates each sentence once it is finalized, using the highest-quality translation model available (Apple Intelligence high fidelity on supported systems)."
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
        guard let current = store.languagePair.translationTarget else {
            return translationLanguages
        }
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
            store.languagePair.translationTarget?.maximalIdentifier
                ?? LanguagePair.noneTargetValue
        } set: { identifier in
            store.languagePair.translationTarget =
                identifier == LanguagePair.noneTargetValue
                ? nil : Locale.Language(identifier: identifier)
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
