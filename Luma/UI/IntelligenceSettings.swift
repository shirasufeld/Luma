import Foundation

nonisolated enum IntelligenceSettingsKey {
    static let proofreadTranscription = "intelligence.proofreadTranscription"
    static let proofreadTranslation = "intelligence.proofreadTranslation"
}

/// Smart-proofread axis toggles. Both default ON when the keys have never
/// been written (`object(forKey:)` nil), so the feature is discoverable
/// without burying new users in Settings first.
nonisolated enum IntelligenceSettings {
    static func proofreadOptions(from defaults: UserDefaults = .standard) -> ProofreadOptions {
        ProofreadOptions(
            transcription: bool(defaults, IntelligenceSettingsKey.proofreadTranscription),
            translation: bool(defaults, IntelligenceSettingsKey.proofreadTranslation))
    }

    private static func bool(_ defaults: UserDefaults, _ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
