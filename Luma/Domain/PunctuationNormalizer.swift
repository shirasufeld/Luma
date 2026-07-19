import Foundation

/// One (entry id, display text) pair flowing through proofread normalization
/// and chunking.
nonisolated struct ProofreadSentence: Sendable, Equatable {
    var id: UUID
    var text: String
}

/// Deterministic cleanup of speech-recognizer segmentation artifacts, run
/// before the model pass. The recognizer regularly attaches a sentence-final
/// punctuation mark to the START of the next finalized segment ("。这里有…",
/// ", so the current…"); moving it back is mechanical string work — doing it
/// with rules keeps the model focused on real recognition errors and cannot
/// hallucinate.
nonisolated enum PunctuationNormalizer {

    /// Closing punctuation that can never legitimately begin a sentence,
    /// across the scripts the transcriber supports: CJK fullwidth, Latin,
    /// Arabic (، ؛ ؟ ۔), and Devanagari (। ॥). Opening marks that DO start
    /// sentences (Spanish ¿ ¡, quotes, brackets) are deliberately absent.
    private static let leadingStrays = Set("。，、？！；：…,.?!;:،؛؟۔।॥")

    /// Punctuation that already terminates a clause/sentence — a stray is
    /// dropped rather than doubled onto such an ending.
    private static let terminalPunctuation = Set("。，、？！；：…,.?!;:،؛؟۔।॥")

    /// Moves leading stray punctuation of each sentence onto the end of the
    /// sentence before it (or drops it when that sentence already ends with
    /// punctuation). `previous` is the entry just before the scope, so the
    /// scope's first sentence can hand its stray back across the boundary.
    ///
    /// Returns the normalized scope sentences (same order and ids) plus
    /// every changed text keyed by entry id — including `previous.id` when
    /// the boundary hand-off changed it.
    static func normalize(
        _ sentences: [ProofreadSentence], previous: ProofreadSentence? = nil
    ) -> (sentences: [ProofreadSentence], changes: [UUID: String]) {
        var work = sentences
        var previousEntry = previous

        for index in work.indices {
            let original = work[index].text
            var remainder = Substring(original)

            var stray = ""
            while let first = remainder.first, leadingStrays.contains(first) {
                stray.append(first)
                remainder = remainder.dropFirst()
            }
            let stripped = remainder.trimmingCharacters(in: .whitespaces)
            // A punctuation-only entry has nothing left to show; leave it.
            guard !stray.isEmpty, !stripped.isEmpty else { continue }

            work[index].text = stripped
            if index > 0 {
                work[index - 1].text = appending(stray, to: work[index - 1].text)
            } else if let target = previousEntry {
                previousEntry?.text = appending(stray, to: target.text)
            }
            // No earlier sentence to receive it: the stray is dropped.
        }

        var changes: [UUID: String] = [:]
        for (normalized, original) in zip(work, sentences) where normalized.text != original.text {
            changes[normalized.id] = normalized.text
        }
        if let previousEntry, let previous, previousEntry.text != previous.text {
            changes[previous.id] = previousEntry.text
        }
        return (work, changes)
    }

    /// Appends stray punctuation unless the receiving sentence already ends
    /// with punctuation (then the stray is redundant and dropped).
    private static func appending(_ stray: String, to text: String) -> String {
        guard let last = text.last, !terminalPunctuation.contains(last) else { return text }
        return text + stray
    }
}
