import Foundation

/// On-device translation of finalized caption lines.
nonisolated protocol TranslationProviding: Sendable {
    /// Configures (or reconfigures) the language pair and reports whether
    /// translation is ready, needs a model download, or is unsupported.
    func setLanguagePair(
        source: Locale.Language,
        target: Locale.Language
    ) async -> TranslationAvailability

    /// Translates one line. Only valid while the pair is `.installed`.
    func translate(_ text: String) async throws -> String
}

nonisolated enum TranslationPipelineError: Error, Equatable {
    case languagePairNotReady
}
