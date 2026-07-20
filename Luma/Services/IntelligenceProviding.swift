import Foundation

/// One source sentence and its current translation, sent together so the
/// model can fix translation errors against the source.
nonisolated struct ProofreadPair: Sendable, Equatable {
    var source: String
    var translation: String
}

/// Structured output of the summary operation.
nonisolated struct TranscriptSummary: Sendable, Equatable {
    var abstract: String
    var keyPoints: [String]
}

/// One row of the convert-to-table operation.
nonisolated struct TranscriptTableRow: Sendable, Equatable {
    var topic: String
    var detail: String
}

/// Prose-transformation styles of the rewrite pipeline. All run chunk-by-
/// chunk in order; prose styles carry the previous chunk's tail for
/// continuity.
nonisolated enum RewriteStyle: String, Sendable, Equatable {
    /// Readable prose, strictly faithful (the original 重新排版).
    case reformat
    /// Clearer wording; may reorganize for flow.
    case rewrite
    case friendly
    case professional
    case concise
    /// Full-coverage markdown bullet items.
    case bulletList
}

/// Domain-level failures of the on-device model; implementations map the
/// OS error types here so nothing above Infrastructure imports
/// FoundationModels.
nonisolated enum IntelligenceError: Error, Equatable {
    case unavailable
    case contextWindowExceeded
    case guardrailViolation
    case refusal
    case unsupportedLanguage
    case rateLimited
    case decodingFailure
    case other(String)
}

/// On-device generative features: smart proofread and rewrite. Everything
/// above the Services layer sees only this protocol.
nonisolated protocol IntelligenceProviding: Sendable {
    /// Model availability for a locale (mirrors `CapabilityChecking` for
    /// callers that only hold this protocol).
    func availability(for locale: Locale) async -> AppleIntelligenceAvailability

    /// Whether the model also covers this language (translation targets).
    func supportsLanguage(_ language: Locale.Language) async -> Bool

    /// Precise model token count on 26.4+, nil below (callers fall back to
    /// `IntelligenceChunker.estimatedTokens`).
    func tokenCount(for text: String) async -> Int?

    /// Sparse corrections keyed by 1-based index into `sentences`; sentences
    /// without recognition errors are absent. `context` is a read-only
    /// preceding sentence.
    func proofreadTranscription(
        sentences: [String], context: String?, locale: Locale
    ) async throws -> [Int: String]

    /// Sparse corrected translations keyed by 1-based index into `pairs`.
    func proofreadTranslation(
        pairs: [ProofreadPair], locale: Locale, target: Locale.Language
    ) async throws -> [Int: String]

    /// Map step: summarize one chunk of transcript.
    func summarize(chunk: String, locale: Locale) async throws -> TranscriptSummary

    /// Reduce step: merge per-chunk summaries into one.
    func combineSummaries(
        _ parts: [TranscriptSummary], locale: Locale
    ) async throws -> TranscriptSummary

    /// Topic/detail rows for the convert-to-table operation (map-only;
    /// callers concatenate rows across chunks).
    func tableRows(chunk: String, locale: Locale) async throws -> [TranscriptTableRow]

    /// Rewrites one chunk in the given style; `previousTail` is the end of
    /// the previous chunk's output, for continuity in prose styles.
    func rewrite(
        chunk: String, previousTail: String?, locale: Locale, style: RewriteStyle
    ) async throws -> String
}
