import CoreMedia
import Foundation
import Testing

@testable import Luma

@MainActor
struct SessionControllerTests {

    private func makeController(
        events: [TranscriptEvent],
        translator: MockTranslator = MockTranslator()
    ) -> (SessionStore, SessionController) {
        let store = SessionStore()
        let controller = SessionController(
            store: store,
            capabilities: MockCapabilities(),
            transcription: MockTranscriber(events: events),
            translation: translator,
            audioProviderFactory: { _ in MockAudioProvider() })
        return (store, controller)
    }

    @Test func fullSessionFlowDeliversEntriesAndTranslations() async {
        let segment1 = makeSegment("first line", start: 0, end: 1)
        let segment2 = makeSegment("second line", start: 1, end: 2)
        let (store, controller) = makeController(events: [
            .volatile(text: AttributedString("fir"), range: segment1.range),
            .finalized(segment1),
            .finalized(segment2),
            .finalized(segment2),  // duplicate must be dropped
        ])

        await controller.start(languagePair: .default, inputKind: .microphone)
        #expect(store.sessionState == .running)
        #expect(store.modelState == .ready)
        #expect(store.translationAvailability == .installed)

        let delivered = await waitUntil {
            store.entries.count == 2
                && store.entries.allSatisfy { entry in
                    if case .translated = entry.translation { return true }
                    return false
                }
        }
        #expect(delivered, "expected 2 deduplicated, translated entries")
        #expect(store.entries[0].translation == .translated("«first line»"))
        #expect(store.entries[1].translation == .translated("«second line»"))

        await controller.stop()
        #expect(store.sessionState == .idle)
        #expect(store.audioInput == .idle)
    }

    @Test func deniedMicrophoneFailsSession() async {
        let store = SessionStore()
        let controller = SessionController(
            store: store,
            capabilities: MockCapabilities(microphone: .denied),
            transcription: MockTranscriber(events: []),
            translation: MockTranslator(),
            audioProviderFactory: { _ in MockAudioProvider() })

        await controller.start(languagePair: .default, inputKind: .microphone)
        #expect(store.sessionState == .idle)
        #expect(store.errorMessage != nil)
        if case .failed = store.audioInput {
        } else {
            Issue.record("expected audioInput == .failed")
        }
    }

    @Test func unsupportedPairMarksEntriesUnavailable() async {
        let segment = makeSegment("no translation", start: 0, end: 1)
        let (store, controller) = makeController(
            events: [.finalized(segment)],
            translator: MockTranslator(availability: .unsupported))

        await controller.start(languagePair: .default, inputKind: .microphone)
        let delivered = await waitUntil {
            store.entries.count == 1 && store.entries[0].translation == .unavailable
        }
        #expect(delivered, "entry should be marked unavailable when pair unsupported")
        await controller.stop()
    }

    @Test func fastModeTranslatesVolatileText() async {
        let range = makeSegment("x", start: 0, end: 1).range
        let (store, controller) = makeController(events: [
            .volatile(text: AttributedString("hello there"), range: range)
        ])

        await controller.start(
            languagePair: .default, inputKind: .microphone, translationMode: .fast)
        let delivered = await waitUntil {
            store.volatileTranslation == "«hello there»"
        }
        #expect(delivered, "fast mode should live-translate the volatile line")
        await controller.stop()
    }

    @Test func balancedModeDoesNotTranslateVolatileText() async {
        let range = makeSegment("x", start: 0, end: 1).range
        let (store, controller) = makeController(events: [
            .volatile(text: AttributedString("hello there"), range: range)
        ])

        await controller.start(
            languagePair: .default, inputKind: .microphone, translationMode: .balanced)
        // Give the pipeline a moment; no volatile translation may appear.
        _ = await waitUntil(timeout: .milliseconds(300)) { false }
        #expect(store.volatileTranslation == nil)
        await controller.stop()
    }

    @Test func stopDrainsQueuedTranslationsBeforeReturning() async {
        let (store, controller) = makeController(
            events: [
                .finalized(makeSegment("one", start: 0, end: 1)),
                .finalized(makeSegment("two", start: 1, end: 2)),
                .finalized(makeSegment("three", start: 2, end: 3)),
            ],
            translator: MockTranslator(delay: .milliseconds(80)))

        await controller.start(languagePair: .default, inputKind: .microphone)
        let arrived = await waitUntil { store.entries.count == 3 }
        #expect(arrived)
        await controller.stop()
        // stop() waits for the translation queue to drain; nothing may still
        // be pending once it returns.
        let allTranslated = store.entries.allSatisfy { entry in
            if case .translated = entry.translation { return true }
            return false
        }
        #expect(allTranslated, "queued translations must finish before stop() returns")
    }

    @Test func staleVolatileTranslationIsDiscarded() {
        let store = SessionStore()
        store.applyVolatile(
            text: AttributedString("hello"),
            range: CMTimeRange(
                start: .zero, end: CMTime(seconds: 1, preferredTimescale: 600)),
            latency: nil)
        store.applyFinalized(makeSegment("hello", start: 0, end: 1), latency: nil)
        // A translation that was in flight when the line finalized must not
        // resurrect the dismissed volatile line's translation.
        store.applyVolatileTranslation("«stale»")
        #expect(store.volatileTranslation == nil)
    }

    @Test func startIsIgnoredWhileRunning() async {
        let (store, controller) = makeController(events: [])
        await controller.start(languagePair: .default, inputKind: .microphone)
        #expect(store.sessionState == .running)
        // Second start must not disturb the running session.
        await controller.start(languagePair: .default, inputKind: .microphone)
        #expect(store.sessionState == .running)
        await controller.stop()
        #expect(store.sessionState == .idle)
    }
}
