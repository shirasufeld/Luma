import Foundation

/// Pure token-budget packer for on-device model requests: groups consecutive
/// transcript sentences into chunks that fit the context window, carrying one
/// trailing sentence of the previous chunk as read-only context.
nonisolated enum IntelligenceChunker {

    struct Chunk: Sendable, Equatable {
        var entryIDs: [UUID]
        var sentences: [String]
        var contextSentence: String?
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

    static func chunks(
        entries: [(id: UUID, text: String)],
        budget: Int,
        initialContext: String?,
        cost: (String) -> Int = estimatedTokens
    ) -> [Chunk] {
        var result: [Chunk] = []
        var ids: [UUID] = []
        var sentences: [String] = []
        var running = 0
        var context = initialContext

        func flush() {
            guard !ids.isEmpty else { return }
            result.append(Chunk(entryIDs: ids, sentences: sentences, contextSentence: context))
            context = sentences.last
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
    static func bisect(_ chunk: Chunk) -> (Chunk, Chunk)? {
        guard chunk.sentences.count > 1 else { return nil }
        let mid = chunk.sentences.count / 2
        let first = Chunk(
            entryIDs: Array(chunk.entryIDs[..<mid]),
            sentences: Array(chunk.sentences[..<mid]),
            contextSentence: chunk.contextSentence)
        let second = Chunk(
            entryIDs: Array(chunk.entryIDs[mid...]),
            sentences: Array(chunk.sentences[mid...]),
            contextSentence: chunk.sentences[mid - 1])
        return (first, second)
    }
}
