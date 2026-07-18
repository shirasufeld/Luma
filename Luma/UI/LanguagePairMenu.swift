import SwiftUI

/// Compact main-screen menu for the high-frequency session settings: the
/// language pair and translation mode. Shares the store with
/// Settings › General, so both surfaces stay in sync automatically.
struct LanguagePairMenu: View {
    @Bindable var store: SessionStore
    let capabilities: any CapabilityChecking

    @Environment(\.locale)
    private var displayLocale

    @State private var transcriptionLocales: [Locale] = []
    @State private var translationLanguages: [Locale.Language] = []

    var body: some View {
        Menu {
            Picker("Transcribe", selection: transcriptionSelection) {
                ForEach(displayedTranscriptionLocales, id: \.identifier) { locale in
                    Text(displayName(forLocale: locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)
            .disabled(store.sessionState != .idle)
            Picker("Translate to", selection: translationSelection) {
                ForEach(displayedTranslationLanguages, id: \.maximalIdentifier) { language in
                    Text(displayName(forLanguage: language)).tag(language.maximalIdentifier)
                }
            }
            .pickerStyle(.menu)
            .disabled(store.sessionState != .idle)
            // Mode takes effect on the next start, so it stays enabled.
            Picker("Translation Mode", selection: $store.translationMode) {
                Text("Fast").tag(TranslationMode.fast)
                Text("Balanced").tag(TranslationMode.balanced)
                Text("Accurate").tag(TranslationMode.accurate)
            }
            .pickerStyle(.menu)
        } label: {
            Label {
                // Compact identifier form, mirroring the old status readout.
                Text(
                    "\(store.languagePair.transcriptionLocale.identifier) → \(store.languagePair.translationTarget.minimalIdentifier)"
                )
                .monospacedDigit()
            } icon: {
                Image(systemName: "globe")
            }
        }
        .task {
            transcriptionLocales = await capabilities.supportedTranscriptionLocales()
                .sorted { $0.identifier < $1.identifier }
            translationLanguages = await capabilities.supportedTranslationLanguages()
                .sorted { $0.maximalIdentifier < $1.maximalIdentifier }
        }
    }

    /// The active pair may not be in the fetched lists (before they load, or
    /// for equivalents); always include the current selection so the `Picker`
    /// has a matching tag on every render.
    private var displayedTranscriptionLocales: [Locale] {
        let current = store.languagePair.transcriptionLocale
        if transcriptionLocales.contains(where: { $0.identifier == current.identifier }) {
            return transcriptionLocales
        }
        return [current] + transcriptionLocales
    }

    private var displayedTranslationLanguages: [Locale.Language] {
        let current = store.languagePair.translationTarget
        if translationLanguages.contains(where: { $0.maximalIdentifier == current.maximalIdentifier }
        ) {
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
