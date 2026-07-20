import Foundation
import FoundationModels

// Guided-generation schemas. Sparse by design: the model returns only the
// items that need a change, and the validation gate below rejects anything
// structurally suspicious.

@Generable
private struct SentenceCorrections {
    @Guide(
        description:
            "Exactly one item per numbered input sentence, in the same order — corrected, or copied verbatim when already correct."
    )
    var corrections: [SentenceCorrection]
}

@Generable
private struct SentenceCorrection {
    @Guide(description: "The number of the sentence, copied from the input.")
    var index: Int
    @Guide(description: "The corrected sentence, or the input sentence verbatim when it has no errors.")
    var text: String
}

@Generable
private struct TranslationCorrections {
    @Guide(
        description:
            "Exactly one item per numbered input pair, in the same order — the translation corrected, or copied verbatim when already correct."
    )
    var corrections: [TranslationCorrection]
}

@Generable
private struct TranslationCorrection {
    @Guide(description: "The number of the pair, copied from the input.")
    var index: Int
    @Guide(description: "The corrected translation, or the input translation verbatim when it has no errors.")
    var translation: String
}

@Generable
private struct SummaryDraft {
    @Guide(
        description:
            "A short paragraph of 2-3 sentences abstracting the passage, in the passage's language.")
    var abstract: String
    @Guide(description: "3 to 7 concise key points, in the passage's language.")
    var keyPoints: [String]
}

@Generable
private struct TableRowsDraft {
    @Guide(description: "One row per distinct topic of the passage, in the original order.")
    var rows: [TableRowDraft]
}

@Generable
private struct TableRowDraft {
    @Guide(description: "A short topic name, in the passage's language.")
    var topic: String
    @Guide(description: "A one-sentence detail for the topic, in the passage's language.")
    var detail: String
}

/// FoundationModels-backed engine for smart proofread and rewrite — with
/// `CapabilityService`, the only production code that talks to the on-device
/// language model. Stateless: a fresh short-lived session per request keeps
/// every call inside the context window and off any isolation domain.
nonisolated final class AppleIntelligenceService: IntelligenceProviding {

    @concurrent
    func availability(for locale: Locale) async -> AppleIntelligenceAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .available : .unsupportedLanguage(locale)
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .deviceNotEligible
            }
        }
    }

    @concurrent
    func supportsLanguage(_ language: Locale.Language) async -> Bool {
        SystemLanguageModel.default.supportsLocale(
            Locale(identifier: language.maximalIdentifier))
    }

    @concurrent
    func tokenCount(for text: String) async -> Int? {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try? await SystemLanguageModel.default.tokenCount(for: text)
        }
        return nil
    }

    func proofreadTranscription(
        sentences: [String], context: String?, locale: Locale
    ) async throws -> [Int: String] {
        let raw = try await Self.sentenceCorrections(
            instructions: IntelligencePrompts.transcriptionInstructions(for: locale),
            prompt: IntelligencePrompts.transcriptionPrompt(
                sentences: sentences, context: context))
        return Self.validatedCorrections(raw, against: sentences)
    }

    func proofreadTranslation(
        pairs: [ProofreadPair], locale: Locale, target: Locale.Language
    ) async throws -> [Int: String] {
        let raw = try await Self.translationCorrections(
            instructions: IntelligencePrompts.translationInstructions(
                sourceName: IntelligencePrompts.englishName(for: locale),
                targetName: IntelligencePrompts.englishName(for: target)),
            prompt: IntelligencePrompts.translationPrompt(pairs: pairs))
        return Self.validatedCorrections(raw, against: pairs.map(\.translation))
    }

    @concurrent
    func summarize(chunk: String, locale: Locale) async throws -> TranscriptSummary {
        do {
            let session = try Self.makeSession(
                instructions: IntelligencePrompts.summaryInstructions())
            let response = try await session.respond(
                to: chunk, generating: SummaryDraft.self,
                options: GenerationOptions(maximumResponseTokens: 500))
            return TranscriptSummary(
                abstract: response.content.abstract, keyPoints: response.content.keyPoints)
        } catch {
            throw Self.mapped(error)
        }
    }

    @concurrent
    func combineSummaries(
        _ parts: [TranscriptSummary], locale: Locale
    ) async throws -> TranscriptSummary {
        do {
            let session = try Self.makeSession(
                instructions: IntelligencePrompts.combineInstructions())
            let response = try await session.respond(
                to: IntelligencePrompts.combinePrompt(parts: parts),
                generating: SummaryDraft.self,
                options: GenerationOptions(maximumResponseTokens: 500))
            return TranscriptSummary(
                abstract: response.content.abstract, keyPoints: response.content.keyPoints)
        } catch {
            throw Self.mapped(error)
        }
    }

    @concurrent
    func tableRows(chunk: String, locale: Locale) async throws -> [TranscriptTableRow] {
        do {
            let session = try Self.makeSession(
                instructions: IntelligencePrompts.tableInstructions())
            let response = try await session.respond(
                to: chunk, generating: TableRowsDraft.self,
                options: GenerationOptions(maximumResponseTokens: 800))
            return response.content.rows.map {
                TranscriptTableRow(topic: $0.topic, detail: $0.detail)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    @concurrent
    func rewrite(
        chunk: String, previousTail: String?, locale: Locale, style: RewriteStyle
    ) async throws -> String {
        do {
            let session = try Self.makeSession(
                instructions: IntelligencePrompts.rewriteInstructions(style: style))
            let response = try await session.respond(
                to: IntelligencePrompts.reformatPrompt(chunk: chunk, previousTail: previousTail),
                options: GenerationOptions(maximumResponseTokens: 1800))
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Requests

    @concurrent
    private static func sentenceCorrections(
        instructions: String, prompt: String
    ) async throws -> [(index: Int, text: String)] {
        do {
            let session = try makeSession(instructions: instructions)
            let response = try await session.respond(
                to: prompt, generating: SentenceCorrections.self,
                options: GenerationOptions(
                    samplingMode: .greedy, maximumResponseTokens: 2000))
            return response.content.corrections.map { ($0.index, $0.text) }
        } catch {
            throw mapped(error)
        }
    }

    @concurrent
    private static func translationCorrections(
        instructions: String, prompt: String
    ) async throws -> [(index: Int, text: String)] {
        do {
            let session = try makeSession(instructions: instructions)
            let response = try await session.respond(
                to: prompt, generating: TranslationCorrections.self,
                options: GenerationOptions(
                    samplingMode: .greedy, maximumResponseTokens: 2000))
            return response.content.corrections.map { ($0.index, $0.translation) }
        } catch {
            throw mapped(error)
        }
    }

    /// `permissiveContentTransformations`: Apple's sanctioned guardrail level
    /// for transforming user content — spoken transcripts must not be
    /// spuriously blocked for what they merely mention.
    private static func makeSession(instructions: String) throws -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { throw IntelligenceError.unavailable }
        return LanguageModelSession(model: model, instructions: instructions)
    }

    // MARK: - Validation gate

    /// Rejects structurally suspicious corrections: out-of-range indices,
    /// empty output, no-op echoes, and blow-ups/truncations beyond 3× either
    /// way (hallucination and prompt-injection backstop). Model output is
    /// collapsed to a single line — caption rows never contain newlines.
    static func validatedCorrections(
        _ raw: [(index: Int, text: String)], against originals: [String]
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, text) in raw {
            guard index >= 1, index <= originals.count else { continue }
            let original = originals[index - 1]
            let corrected = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, corrected != original else { continue }
            let ratio = Double(corrected.count) / Double(max(original.count, 1))
            guard ratio >= 1.0 / 3.0, ratio <= 3.0 else { continue }
            result[index] = corrected
        }
        return result
    }

    // MARK: - Error mapping

    /// Central beta-drift absorber. `GenerationError` is deprecated on 27 but
    /// still thrown by the 26-era respond overloads — matching its cases
    /// warns until 26 support drops; keep both paths.
    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError || error is IntelligenceError { return error }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return IntelligenceError.contextWindowExceeded
            case .guardrailViolation: return IntelligenceError.guardrailViolation
            case .refusal: return IntelligenceError.refusal
            case .unsupportedLanguageOrLocale: return IntelligenceError.unsupportedLanguage
            case .rateLimited, .concurrentRequests: return IntelligenceError.rateLimited
            case .assetsUnavailable: return IntelligenceError.unavailable
            case .decodingFailure, .unsupportedGuide: return IntelligenceError.decodingFailure
            @unknown default: return IntelligenceError.other(String(describing: generation))
            }
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded: return IntelligenceError.contextWindowExceeded
                case .guardrailViolation: return IntelligenceError.guardrailViolation
                case .refusal: return IntelligenceError.refusal
                case .unsupportedLanguageOrLocale: return IntelligenceError.unsupportedLanguage
                case .rateLimited, .timeout: return IntelligenceError.rateLimited
                case .unsupportedCapability, .unsupportedTranscriptContent,
                    .unsupportedGenerationGuide:
                    return IntelligenceError.decodingFailure
                @unknown default: return IntelligenceError.other(String(describing: modelError))
                }
            }
        }
        return IntelligenceError.other(error.localizedDescription)
    }
}
