import Foundation

/// On-device translation of finalized caption lines.
nonisolated protocol TranslationProviding: Sendable {
    /// Configures (or reconfigures) the language pair and reports whether
    /// translation is ready, needs a model download, or is unsupported.
    /// `mode` selects the latency/fidelity trade-off where the OS supports
    /// translation strategies (macOS 26.4+).
    func setLanguagePair(
        source: Locale.Language,
        target: Locale.Language,
        mode: TranslationMode
    ) async -> TranslationAvailability

    /// Translates one line. Only valid while the pair is `.installed`.
    func translate(_ text: String) async throws -> String
}

nonisolated enum TranslationPipelineError: Error, Equatable {
    case languagePairNotReady
}
