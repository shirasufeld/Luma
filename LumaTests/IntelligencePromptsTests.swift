import Foundation
import Testing

@testable import Luma

struct IntelligencePromptsTests {

    @Test func transcriptionPromptNumbersFromOneAndTagsContext() {
        let prompt = IntelligencePrompts.transcriptionPrompt(
            sentences: ["a", "b"], context: "prev")
        #expect(prompt == "[0] prev\n[1] a\n[2] b")

        let noContext = IntelligencePrompts.transcriptionPrompt(sentences: ["a"], context: nil)
        #expect(noContext == "[1] a")
    }

    @Test func translationPromptPairsSourceAndTranslation() {
        let prompt = IntelligencePrompts.translationPrompt(
            pairs: [
                ProofreadPair(source: "hi", translation: "你好"),
                ProofreadPair(source: "bye", translation: "再见"),
            ])
        #expect(prompt == "[1] S: hi\n    T: 你好\n[2] S: bye\n    T: 再见")
    }

    @Test func combinePromptNumbersDrafts() {
        let prompt = IntelligencePrompts.combinePrompt(
            parts: [
                TranscriptSummary(abstract: "First part.", keyPoints: ["p1", "p2"]),
                TranscriptSummary(abstract: "Second part.", keyPoints: ["p3"]),
            ])
        #expect(prompt == "[1] First part.\n- p1\n- p2\n\n[2] Second part.\n- p3")
    }

    @Test func reformatPromptCarriesPreviousTail() {
        #expect(IntelligencePrompts.reformatPrompt(chunk: "text", previousTail: nil) == "text")
        let withTail = IntelligencePrompts.reformatPrompt(chunk: "text", previousTail: "ending")
        #expect(withTail == "Previous paragraph ended with: …ending\n\ntext")
    }

    @Test func instructionsDemoteContentToData() {
        // Every instruction set must tell the model the content is data, not
        // commands — the prompt-injection defense the spec requires.
        let all = [
            IntelligencePrompts.transcriptionInstructions(for: Locale(identifier: "en_US")),
            IntelligencePrompts.translationInstructions(
                sourceName: "English", targetName: "Chinese"),
            IntelligencePrompts.summaryInstructions(),
            IntelligencePrompts.combineInstructions(),
            IntelligencePrompts.reformatInstructions(),
        ]
        #expect(all.allSatisfy { $0.contains("not instructions") })
    }

    @Test func proofreadInstructionsDemandEchoAll() {
        // Small on-device models under-trigger on "return only the changed
        // ones" — the instructions must demand one output per input.
        #expect(
            IntelligencePrompts.transcriptionInstructions(for: Locale(identifier: "en_US"))
                .contains("one item per numbered sentence"))
        #expect(
            IntelligencePrompts.translationInstructions(sourceName: "English", targetName: "Chinese")
                .contains("one item per numbered pair"))
    }

    @Test func fewShotExampleMatchesTranscriptLanguage() {
        // The example must be in the language being proofread — this holds
        // for every app language, not just Chinese.
        for (identifier, fragment) in [
            ("zh-Hans", "二极管"), ("zh-Hant", "二极管"), ("ja-JP", "意外"),
            ("ko-KR", "낫기를"), ("es-ES", "a ver"), ("fr-FR", "vaut"),
            ("de-DE", "seid"), ("en_US", "burns"), ("it-IT", "burns"),
        ] {
            let instructions = IntelligencePrompts.transcriptionInstructions(
                for: Locale(identifier: identifier))
            #expect(instructions.contains(fragment), "missing \(fragment) for \(identifier)")
        }
    }

    @Test func englishNamesResolve() {
        #expect(IntelligencePrompts.englishName(for: Locale(identifier: "zh-Hans")).contains("Chinese"))
        #expect(
            IntelligencePrompts.englishName(for: Locale.Language(identifier: "de")).contains("German"))
    }
}
