import CoreMedia
import Foundation
import Testing

@testable import Luma

@MainActor
struct ProofreadCoordinatorTests {

    private func seededStore(_ texts: [String]) -> (SessionStore, [TranscriptSegment]) {
        let store = SessionStore()
        var segments: [TranscriptSegment] = []
        for (index, text) in texts.enumerated() {
            let segment = makeSegment(text, start: Double(index), end: Double(index) + 1)
            segments.append(segment)
            store.applyFinalized(segment, latency: nil)
        }
        return (store, segments)
    }

    private let english = Locale(identifier: "en_US")

    @Test func appliesCorrectionsAndKeepsBoundary() async {
        let (store, segments) = seededStore(["helo", "wrld"])
        let mock = MockIntelligence(transcription: [.success([1: "hello", 2: "world"])])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle && store.canRevertProofread })
        #expect(store.entries.map(\.displayText) == ["hello", "world"])
        #expect(store.entries.map(\.segment.plainText) == ["helo", "wrld"])
        #expect(store.proofreadBoundaryID == segments[1].id)
        #expect(store.proofreadMessage == nil)
    }

    @Test func pendingTranslationEntriesGetSourceOnlyPass() async {
        let (store, segments) = seededStore(["one", "two"])
        store.applyTranslation(segmentID: segments[0].id, state: .translated("哈喽"))
        // segments[1] stays .pending — its translation must not reach the model.
        let mock = MockIntelligence(
            transcription: [.success([:])],
            translation: [.success([1: "你好"])])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: true),
            locale: english, target: Locale.Language(identifier: "zh-Hans"))

        #expect(await waitUntil { store.proofreadActivity == .idle })
        let pairCalls = await mock.translationCalls
        #expect(pairCalls.count == 1)
        #expect(pairCalls[0] == [ProofreadPair(source: "one", translation: "哈喽")])
        #expect(store.entries[0].displayTranslatedText == "你好")
        #expect(store.entries[1].correctedTranslation == nil)
    }

    @Test func failedChunkIsIsolated() async {
        let (store, segments) = seededStore(["a1", "b2", "c3"])
        // Budget 1 → one entry per chunk; chunk 2 hits the guardrail.
        let mock = MockIntelligence(
            transcription: [
                .success([1: "A1"]),
                .failure(.guardrailViolation),
                .success([1: "C3"]),
            ])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock, inputBudget: 1)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle })
        #expect(store.entries.map(\.displayText) == ["A1", "b2", "C3"])
        #expect(store.proofreadBoundaryID == segments[2].id)
        #expect(store.proofreadMessage == nil)
    }

    @Test func contextOverflowBisectsAndRetries() async {
        let (store, _) = seededStore(["a1", "b2"])
        let mock = MockIntelligence(
            transcription: [
                .failure(.contextWindowExceeded),
                .success([1: "A1"]),
                .success([1: "B2"]),
            ])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle })
        let calls = await mock.transcriptionCalls
        #expect(calls.count == 3)
        #expect(calls[0] == ["a1", "b2"])
        #expect(calls[1] == ["a1"])
        #expect(calls[2] == ["b2"])
        #expect(store.entries.map(\.displayText) == ["A1", "B2"])
    }

    @Test func allChunksFailedRollsBackBoundaryWithMessage() async {
        let (store, _) = seededStore(["a1", "b2"])
        let mock = MockIntelligence(
            transcription: [.failure(.guardrailViolation), .failure(.refusal)])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock, inputBudget: 1)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle })
        #expect(store.proofreadBoundaryID == nil)
        #expect(!store.canRevertProofread)
        #expect(store.proofreadMessage != nil)
        #expect(store.entries.map(\.displayText) == ["a1", "b2"])
    }

    @Test func unsupportedLanguageAbortsRun() async {
        let (store, _) = seededStore(["a1"])
        let mock = MockIntelligence(transcription: [.failure(.unsupportedLanguage)])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle })
        #expect(store.proofreadBoundaryID == nil)
        #expect(store.proofreadMessage != nil)
    }

    @Test func cancelKeepsAppliedChunksAndRollsBoundaryBack() async {
        let (store, segments) = seededStore(["a1", "b2", "c3"])
        let mock = MockIntelligence(
            transcription: [.success([1: "A1"]), .success([1: "B2"]), .success([1: "C3"])],
            delay: .milliseconds(300))
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock, inputBudget: 1)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)
        #expect(await waitUntil { store.entries[0].displayText == "A1" })

        await coordinator.cancelActiveRun()
        #expect(store.proofreadActivity == .idle)
        // Chunk 1 stays applied; the divider honestly marks how far we got.
        #expect(store.entries[0].displayText == "A1")
        #expect(store.proofreadBoundaryID == segments[0].id)
        #expect(store.canRevertProofread)
    }

    @Test func revertRestoresOriginalsAndBoundary() async {
        let (store, _) = seededStore(["helo"])
        let mock = MockIntelligence(transcription: [.success([1: "hello"])])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)
        #expect(await waitUntil { store.proofreadActivity == .idle })
        #expect(store.entries[0].displayText == "hello")

        await coordinator.revertLast()
        #expect(store.entries[0].displayText == "helo")
        #expect(store.proofreadBoundaryID == nil)
        #expect(!store.canRevertProofread)
    }

    @Test func unavailableModelIsANoOp() async {
        let (store, _) = seededStore(["a1"])
        let mock = MockIntelligence(transcription: [], availability: .notEnabled)
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)

        #expect(store.proofreadActivity == .idle)
        #expect(store.proofreadBoundaryID == nil)
    }

    @Test func punctuationStraysAreFixedWithoutModelHelp() async {
        let (store, segments) = seededStore(["第一句还没有结尾", "。第二句从标点开始"])
        // Model reports nothing to correct; the deterministic pre-pass alone
        // must fix the recognizer's stray-punctuation artifact.
        let mock = MockIntelligence(transcription: [.success([:])])
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: Locale(identifier: "zh-Hans"), target: nil)

        #expect(await waitUntil { store.proofreadActivity == .idle })
        #expect(store.entries.map(\.displayText) == ["第一句还没有结尾。", "第二句从标点开始"])
        #expect(store.entries.map(\.segment.plainText) == ["第一句还没有结尾", "。第二句从标点开始"])
        #expect(store.canRevertProofread)
        // The model saw the normalized text, not the raw artifact.
        let calls = await mock.transcriptionCalls
        #expect(calls == [["第一句还没有结尾。", "第二句从标点开始"]])
        #expect(store.proofreadBoundaryID == segments[1].id)
    }

    @Test func sessionStartAndClearCancelInflightRun() async {
        let (store, _) = seededStore(["a1", "b2", "c3"])
        let mock = MockIntelligence(
            transcription: [.success([1: "A1"]), .success([1: "B2"]), .success([1: "C3"])],
            delay: .milliseconds(400))
        let coordinator = ProofreadCoordinator(store: store, intelligence: mock, inputBudget: 1)
        let controller = SessionController(
            store: store,
            capabilities: MockCapabilities(),
            transcription: MockTranscriber(events: []),
            translation: MockTranslator(),
            audioProviderFactory: { _ in MockAudioProvider() },
            proofreader: coordinator)

        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)
        #expect(await waitUntil { store.proofreadActivity != .idle })

        // Starting a new session must first cancel and settle the run.
        await controller.start(languagePair: .default, inputKind: .microphone)
        #expect(store.proofreadActivity == .idle)
        await controller.stop()

        // Same for clearing the transcript mid-run.
        await coordinator.startProofread(
            options: ProofreadOptions(transcription: true, translation: false),
            locale: english, target: nil)
        #expect(await waitUntil { store.proofreadActivity != .idle })
        await controller.clearTranscript()
        #expect(store.proofreadActivity == .idle)
        #expect(store.entries.isEmpty)
        #expect(store.proofreadBoundaryID == nil)
    }
}
