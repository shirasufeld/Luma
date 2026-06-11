import CoreMedia
import Foundation

@testable import Luma

/// Capability checker with fixed answers.
nonisolated struct MockCapabilities: CapabilityChecking {
    var microphone: PermissionState = .granted
    var transcription: TranscriptionAvailability = .installed(Locale(identifier: "en-US"))
    var translation: TranslationAvailability = .installed

    func microphonePermission() -> PermissionState { microphone }
    func requestMicrophonePermission() async -> PermissionState { microphone }
    func transcriptionAvailability(for locale: Locale) async -> TranscriptionAvailability {
        transcription
    }
    func supportedTranscriptionLocales() async -> [Locale] { [Locale(identifier: "en-US")] }
    func translationAvailability(
        from source: Locale.Language, to target: Locale.Language
    ) async -> TranslationAvailability { translation }
    func supportedTranslationLanguages() async -> [Locale.Language] {
        [Locale.Language(identifier: "zh-Hans")]
    }
}

/// Audio provider that emits no audio; the mock transcriber scripts events
/// independently of audio content.
actor MockAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .microphone
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var started = false
    private(set) var stopped = false

    func start() throws -> AsyncStream<AudioChunk> {
        started = true
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func pause() {}
    func resume() throws {}

    func stop() {
        stopped = true
        continuation?.finish()
        continuation = nil
    }
}

/// Transcriber that replays a scripted list of events when started and
/// finishes its stream on `finish()`.
actor MockTranscriber: TranscriptionProviding {
    private let scriptedEvents: [TranscriptEvent]
    private var continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?

    init(events: [TranscriptEvent]) {
        scriptedEvents = events
    }

    func prepare(
        locale: Locale,
        onModelState: @escaping @Sendable (TranscriptionModelState) -> Void
    ) async throws -> Locale {
        onModelState(.ready)
        return locale
    }

    func start(
        consuming audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: TranscriptEvent.self, throwing: (any Error).self)
        self.continuation = continuation
        for event in scriptedEvents {
            continuation.yield(event)
        }
        return stream
    }

    func finish() async throws {
        continuation?.finish()
        continuation = nil
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
    }
}

/// Translator that wraps text in guillemets so tests can assert the mapping.
actor MockTranslator: TranslationProviding {
    private let availability: TranslationAvailability

    init(availability: TranslationAvailability = .installed) {
        self.availability = availability
    }

    func setLanguagePair(
        source: Locale.Language, target: Locale.Language
    ) async -> TranslationAvailability { availability }

    func translate(_ text: String) async throws -> String { "«\(text)»" }
}

// MARK: - Shared helpers

nonisolated func makeSegment(
    _ text: String, start: Double, end: Double, id: UUID = UUID()
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        text: AttributedString(text),
        range: CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)))
}

/// Polls until `condition` is true or the timeout elapses.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
