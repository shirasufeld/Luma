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

    var id: UUID { segment.id }

    init(segment: TranscriptSegment, translation: TranslationState = .pending) {
        self.segment = segment
        self.translation = translation
    }
}
