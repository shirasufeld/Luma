import Foundation

/// The active language configuration: which locale to transcribe and which
/// language to translate finalized captions into.
nonisolated struct LanguagePair: Sendable, Equatable {
    /// Locale used by the transcription engine (e.g. `en-US`).
    var transcriptionLocale: Locale
    /// Target language for translation (e.g. `zh-Hans`).
    var translationTarget: Locale.Language

    /// Source language derived from the transcription locale, used for
    /// translation availability checks and sessions.
    var translationSource: Locale.Language {
        transcriptionLocale.language
    }

    static let `default` = LanguagePair(
        transcriptionLocale: Locale(identifier: "en-US"),
        translationTarget: Locale.Language(identifier: "zh-Hans")
    )
}
