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
            entries: entries, budget: 80, initialContext: "prior", cost: { _ in 40 })
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.sentences.count == 2 })
        #expect(chunks[0].contextSentence == "prior")
        #expect(chunks[1].contextSentence == chunks[0].sentences.last)
        #expect(chunks[2].contextSentence == chunks[1].sentences.last)
        #expect(chunks.flatMap(\.entryIDs) == entries.map(\.id))
    }

    @Test func oversizedSingleSentenceGetsOwnChunk() {
        let entries = [(id: UUID(), text: "big")]
        let chunks = IntelligenceChunker.chunks(
            entries: entries, budget: 1, initialContext: nil, cost: { _ in 999 })
        #expect(chunks.count == 1)
        #expect(chunks[0].sentences == ["big"])
    }

    @Test func bisectSplitsAndRefusesSingles() {
        let ids = [UUID(), UUID(), UUID()]
        let chunk = IntelligenceChunker.Chunk(
            entryIDs: ids, sentences: ["a", "b", "c"], contextSentence: "x")
        let halves = IntelligenceChunker.bisect(chunk)
        #expect(halves != nil)
        if let (first, second) = halves {
            #expect(first.sentences == ["a"])
            #expect(first.contextSentence == "x")
            #expect(second.sentences == ["b", "c"])
            #expect(second.contextSentence == "a")
            #expect(first.entryIDs + second.entryIDs == ids)
            #expect(IntelligenceChunker.bisect(first) == nil)
        }
    }
}
