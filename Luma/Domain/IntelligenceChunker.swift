import Foundation

/// Pure token-budget packer for on-device model requests: groups consecutive
/// transcript sentences into chunks that fit the context window, carrying a
/// token-budgeted tail of the previous chunk as read-only context so
/// corrections stay consistent across chunk boundaries.
nonisolated enum IntelligenceChunker {

    /// Budget for the read-only context carried between chunks, in estimated
    /// tokens. Small against the ~4096 window: instructions (~350) + context
    /// + input + echo-all output must all fit.
    static let defaultContextBudget = 150
    /// Cap on carried context sentences regardless of how cheap they are.
    static let maxContextSentences = 4

    struct Chunk: Sendable, Equatable {
        var entryIDs: [UUID]
        var sentences: [String]
        var contextSentences: [String]

        /// The context as a single prompt line (`[0] …`), nil when empty.
        var contextText: String? {
            contextSentences.isEmpty ? nil : contextSentences.joined(separator: " ")
        }
    }

    /// Conservative estimate for OS 26.0–26.3, where no tokenCount API
    /// exists: CJK ≈ 1 token/char (safe upper bound), other scripts ≈ 3
    /// chars/token, plus per-sentence numbering overhead. Over-splitting is
    /// acceptable; under-splitting is caught by error-driven bisect.
    static func estimatedTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF,
                0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + (other + 2) / 3 + 6
    }

    /// The trailing sentences that fit the context budget, newest last. The
    /// final sentence is always included — parity with the unconditional
    /// single-sentence carry this evolved from.
    static func trailingContext(
        of sentences: [String],
        budget: Int,
        maxSentences: Int,
        cost: (String) -> Int = estimatedTokens
    ) -> [String] {
        var context: [String] = []
        var running = 0
        for sentence in sentences.reversed() {
            let sentenceCost = cost(sentence)
            if !context.isEmpty, running + sentenceCost > budget || context.count >= maxSentences {
                break
            }
            context.insert(sentence, at: 0)
            running += sentenceCost
        }
        return context
    }

    static func chunks(
        entries: [(id: UUID, text: String)],
        budget: Int,
        initialContext: [String],
        contextBudget: Int = defaultContextBudget,
        maxContextSentences: Int = maxContextSentences,
        cost: (String) -> Int = estimatedTokens
    ) -> [Chunk] {
        var result: [Chunk] = []
        var ids: [UUID] = []
        var sentences: [String] = []
        var running = 0
        var context = initialContext

        func flush() {
            guard !ids.isEmpty else { return }
            result.append(Chunk(entryIDs: ids, sentences: sentences, contextSentences: context))
            context = trailingContext(
                of: sentences, budget: contextBudget,
                maxSentences: maxContextSentences, cost: cost)
            ids = []
            sentences = []
            running = 0
        }

        for entry in entries {
            let entryCost = cost(entry.text)
            if !ids.isEmpty, running + entryCost > budget {
                flush()
            }
            ids.append(entry.id)
            sentences.append(entry.text)
            running += entryCost
        }
        flush()
        return result
    }

    /// Splits an over-budget chunk for retry; nil when it cannot shrink.
    /// Bisect is the overflow-recovery path, so both halves also shrink their
    /// context to at most one sentence — retries monotonically reduce load.
    static func bisect(_ chunk: Chunk) -> (Chunk, Chunk)? {
        guard chunk.sentences.count > 1 else { return nil }
        let mid = chunk.sentences.count / 2
        let first = Chunk(
            entryIDs: Array(chunk.entryIDs[..<mid]),
            sentences: Array(chunk.sentences[..<mid]),
            contextSentences: Array(chunk.contextSentences.suffix(1)))
        let second = Chunk(
            entryIDs: Array(chunk.entryIDs[mid...]),
            sentences: Array(chunk.sentences[mid...]),
            contextSentences: [chunk.sentences[mid - 1]])
        return (first, second)
    }
}
