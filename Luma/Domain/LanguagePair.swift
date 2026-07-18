import Foundation

/// The active language configuration: which locale to transcribe and which
/// language to translate finalized captions into.
nonisolated struct LanguagePair: Sendable, Equatable {
    /// Locale used by the transcription engine (e.g. `en-US`).
    var transcriptionLocale: Locale
    /// Target language for translation (e.g. `zh-Hans`), or nil for a
    /// transcription-only session with no translation at all.
    var translationTarget: Locale.Language?

    /// Whether captions should be translated at all.
    var isTranslationEnabled: Bool { translationTarget != nil }

    /// Source language derived from the transcription locale, used for
    /// translation availability checks and sessions.
    var translationSource: Locale.Language {
        transcriptionLocale.language
    }

    /// Sentinel shared by the persistence layer and the two translate-to
    /// pickers to encode "no translation" where a string tag is needed.
    static let noneTargetValue = "none"

    static let `default` = LanguagePair(
        transcriptionLocale: Locale(identifier: "en-US"),
        translationTarget: Locale.Language(identifier: "zh-Hans")
    )
}
