import Foundation

nonisolated enum IntelligenceSettingsKey {
    static let proofreadTranscription = "intelligence.proofreadTranscription"
    static let proofreadTranslation = "intelligence.proofreadTranslation"
    static let proofreadPresets = "intelligence.proofreadPresets"
    static let activeProofreadPresetID = "intelligence.activeProofreadPresetID"
}

/// Smart-proofread axis toggles. Both default ON when the keys have never
/// been written (`object(forKey:)` nil), so the feature is discoverable
/// without burying new users in Settings first.
nonisolated enum IntelligenceSettings {
    static func proofreadOptions(from defaults: UserDefaults = .standard) -> ProofreadOptions {
        var options = ProofreadOptions(
            transcription: bool(defaults, IntelligenceSettingsKey.proofreadTranscription),
            translation: bool(defaults, IntelligenceSettingsKey.proofreadTranslation))
        if let preset = ProofreadPresetStore.activePreset(from: defaults) {
            let content = ProofreadPresetStore.injectionContent(preset.content)
            options.reference = content.isEmpty ? nil : content
        }
        return options
    }

    private static func bool(_ defaults: UserDefaults, _ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
