import Foundation

/// Translation lifecycle for one finalized subtitle line.
nonisolated enum TranslationState: Sendable, Equatable {
    /// Queued for translation (or translation disabled but may be enabled later).
    case pending
    case translated(String)
    /// The language pair is unsupported or translation is turned off.
    case unavailable
    case failed(String)
}

/// One line of the caption history: a finalized transcript segment plus its
/// translation state.
nonisolated struct SubtitleEntry: Sendable, Equatable, Identifiable {
    var segment: TranscriptSegment
    var translation: TranslationState
    /// Smart-proofread corrections; nil = never corrected (or reverted).
    /// The raw transcript in `segment` is never overwritten.
    var correctedText: ProofreadCorrection?
    var correctedTranslation: ProofreadCorrection?

    var id: UUID { segment.id }

    /// What the UI and exports show for the source line.
    var displayText: String { correctedText?.text ?? segment.plainText }

    /// What the UI and exports show for the translation line, when any.
    var displayTranslatedText: String? {
        if let correctedTranslation { return correctedTranslation.text }
        if case .translated(let text) = translation { return text }
        return nil
    }

    init(segment: TranscriptSegment, translation: TranslationState = .pending) {
        self.segment = segment
        self.translation = translation
    }
}
