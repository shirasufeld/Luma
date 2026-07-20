import Foundation
import Testing

@testable import Luma

struct IntelligenceChunkerTests {

    @Test func cjkEstimatesHigherThanLatin() {
        // 8 CJK chars ≈ at least 8 tokens (+ overhead); 5 latin chars stay small.
        #expect(IntelligenceChunker.estimatedTokens("你好世界你好世界") >= 8)
        #expect(IntelligenceChunker.estimatedTokens("hello") <= 10)
    }

    @Test func packsWithinBudgetAndCarriesContext() {
        let entries = (0..<6).map { (id: UUID(), text: "sentence \($0)") }
        let chunks = IntelligenceChunker.chunks(
            entries: entries, budget: 80, initialContext: ["prior"], cost: { _ in 40 })
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.sentences.count == 2 })
        #expect(chunks[0].contextSentences == ["prior"])
        // Both sentences of the previous chunk fit the default context budget.
        #expect(chunks[1].contextSentences == chunks[0].sentences)
        #expect(chunks[2].contextSentences == chunks[1].sentences)
        #expect(chunks.flatMap(\.entryIDs) == entries.map(\.id))
    }

    @Test func oversizedSingleSentenceGetsOwnChunk() {
        let entries = [(id: UUID(), text: "big")]
        let chunks = IntelligenceChunker.chunks(
            entries: entries, budget: 1, initialContext: [], cost: { _ in 999 })
        #expect(chunks.count == 1)
        #expect(chunks[0].sentences == ["big"])
    }

    @Test func multiSentenceContextCarriesAcrossChunks() {
        let entries = (0..<8).map { (id: UUID(), text: "s\($0)") }
        let chunks = IntelligenceChunker.chunks(
            entries: entries, budget: 40, initialContext: [], cost: { _ in 10 })
        #expect(chunks.count == 2)
        #expect(chunks[0].contextSentences == [])
        #expect(chunks[1].contextSentences == ["s0", "s1", "s2", "s3"])
    }

    @Test func contextRespectsItsOwnBudget() {
        // 40-token sentences against the default 150-token context budget:
        // only the trailing three fit.
        let entries = (0..<8).map { (id: UUID(), text: "s\($0)") }
        let chunks = IntelligenceChunker.chunks(
            entries: entries, budget: 160, initialContext: [], cost: { _ in 40 })
        #expect(chunks.count == 2)
        #expect(chunks[1].contextSentences == ["s1", "s2", "s3"])
    }

    @Test func trailingContextRespectsBudgetAndKeepsAtLeastOne() {
        let sentences = ["s1", "s2", "s3", "s4", "s5"]
        let two = IntelligenceChunker.trailingContext(
            of: sentences, budget: 150, maxSentences: 4, cost: { _ in 60 })
        #expect(two == ["s4", "s5"])
        // The final sentence is always carried, even over budget — parity with
        // the unconditional single-sentence carry this evolved from.
        let one = IntelligenceChunker.trailingContext(
            of: sentences, budget: 10, maxSentences: 4, cost: { _ in 999 })
        #expect(one == ["s5"])
        let none = IntelligenceChunker.trailingContext(
            of: [], budget: 150, maxSentences: 4, cost: { _ in 1 })
        #expect(none == [])
    }

    @Test func trailingContextRespectsMaxSentences() {
        let sentences = ["a", "b", "c", "d", "e", "f"]
        let context = IntelligenceChunker.trailingContext(
            of: sentences, budget: 1000, maxSentences: 4, cost: { _ in 1 })
        #expect(context == ["c", "d", "e", "f"])
    }

    @Test func contextTextJoinsWithSingleSpaces() {
        let chunk = IntelligenceChunker.Chunk(
            entryIDs: [], sentences: [], contextSentences: ["Hello.", "World."])
        #expect(chunk.contextText == "Hello. World.")
        let empty = IntelligenceChunker.Chunk(
            entryIDs: [], sentences: [], contextSentences: [])
        #expect(empty.contextText == nil)
    }

    @Test func bisectSplitsAndRefusesSingles() {
        let ids = [UUID(), UUID(), UUID()]
        let chunk = IntelligenceChunker.Chunk(
            entryIDs: ids, sentences: ["a", "b", "c"], contextSentences: ["w", "x"])
        let halves = IntelligenceChunker.bisect(chunk)
        #expect(halves != nil)
        if let (first, second) = halves {
            #expect(first.sentences == ["a"])
            // Bisect is the overflow-recovery path: both halves shrink to at
            // most one context sentence so retries monotonically reduce load.
            #expect(first.contextSentences == ["x"])
            #expect(second.sentences == ["b", "c"])
            #expect(second.contextSentences == ["a"])
            #expect(first.entryIDs + second.entryIDs == ids)
            #expect(IntelligenceChunker.bisect(first) == nil)
        }
    }
}
