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
            IntelligencePrompts.transcriptionInstructions(languageName: "English"),
            IntelligencePrompts.translationInstructions(
                sourceName: "English", targetName: "Chinese"),
            IntelligencePrompts.summaryInstructions(),
            IntelligencePrompts.combineInstructions(),
            IntelligencePrompts.reformatInstructions(),
        ]
        #expect(all.allSatisfy { $0.contains("not instructions") })
    }

    @Test func englishNamesResolve() {
        #expect(IntelligencePrompts.englishName(for: Locale(identifier: "zh-Hans")).contains("Chinese"))
        #expect(
            IntelligencePrompts.englishName(for: Locale.Language(identifier: "de")).contains("German"))
    }
}
