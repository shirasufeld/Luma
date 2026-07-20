import CoreMedia
import Foundation

@testable import Luma

/// Capability checker with fixed answers.
nonisolated struct MockCapabilities: CapabilityChecking {
    var microphone: PermissionState = .granted
    var transcription: TranscriptionAvailability = .installed(Locale(identifier: "en-US"))
    var translation: TranslationAvailability = .installed
    var systemAudioCapture: SystemAudioCaptureStatus = .notAttempted
    var appleIntelligence: AppleIntelligenceAvailability = .available

    func microphonePermission() -> PermissionState { microphone }
    func requestMicrophonePermission() async -> PermissionState { microphone }
    func systemAudioCaptureStatus() -> SystemAudioCaptureStatus { systemAudioCapture }
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
    func appleIntelligenceAvailability(for locale: Locale) async -> AppleIntelligenceAvailability {
        appleIntelligence
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

/// Transcriber whose `finish()` hangs until `cancel()` releases it — models
/// `finalizeAndFinishThroughEndOfInput()` never returning (zero-audio case) so
/// tests can prove the stop path is bounded.
actor HangingTranscriber: TranscriptionProviding {
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelled = false

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
        eventContinuation = continuation
        return stream
    }

    func finish() async throws {
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() async {
        cancelled = true
        finishContinuation?.resume()
        finishContinuation = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }
}

/// Worst-case transcriber: `finish()` AND `cancel()` hang forever and the
/// event stream never ends — replicating the observed device behavior where
/// every SpeechAnalyzer teardown call on a zero-audio session hangs. Only a
/// deadline-and-abandon stop path can get past this one.
actor FullyHangingTranscriber: TranscriptionProviding {
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
        AsyncThrowingStream { _ in }
    }

    func finish() async throws {
        await hangForever()
    }

    func cancel() async {
        await hangForever()
    }

    private func hangForever() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
}

/// Translator that wraps text in guillemets so tests can assert the mapping.
/// An optional per-call delay simulates a slow model for drain-order tests.
actor MockTranslator: TranslationProviding {
    private let availability: TranslationAvailability
    private let delay: Duration

    init(availability: TranslationAvailability = .installed, delay: Duration = .zero) {
        self.availability = availability
        self.delay = delay
    }

    func setLanguagePair(
        source: Locale.Language, target: Locale.Language, mode: TranslationMode
    ) async -> TranslationAvailability { availability }

    func translate(_ text: String) async throws -> String {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return "«\(text)»"
    }
}

/// Intelligence provider with scripted per-call results (FIFO). An optional
/// per-call delay simulates a slow model for cancellation tests.
actor MockIntelligence: IntelligenceProviding {
    private let availabilityAnswer: AppleIntelligenceAvailability
    private let supportsTarget: Bool
    private var transcriptionResults: [Result<[Int: String], IntelligenceError>]
    private var translationResults: [Result<[Int: String], IntelligenceError>]
    private let delay: Duration
    private(set) var transcriptionCalls: [[String]] = []
    private(set) var transcriptionContexts: [String?] = []
    private(set) var translationCalls: [[ProofreadPair]] = []

    init(
        transcription: [Result<[Int: String], IntelligenceError>] = [],
        translation: [Result<[Int: String], IntelligenceError>] = [],
        availability: AppleIntelligenceAvailability = .available,
        supportsTarget: Bool = true,
        delay: Duration = .zero
    ) {
        transcriptionResults = transcription
        translationResults = translation
        availabilityAnswer = availability
        self.supportsTarget = supportsTarget
        self.delay = delay
    }

    func availability(for locale: Locale) async -> AppleIntelligenceAvailability {
        availabilityAnswer
    }

    func supportsLanguage(_ language: Locale.Language) async -> Bool { supportsTarget }

    func tokenCount(for text: String) async -> Int? { nil }

    func proofreadTranscription(
        sentences: [String], context: String?, locale: Locale
    ) async throws -> [Int: String] {
        transcriptionCalls.append(sentences)
        transcriptionContexts.append(context)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard !transcriptionResults.isEmpty else { return [:] }
        return try transcriptionResults.removeFirst().get()
    }

    func proofreadTranslation(
        pairs: [ProofreadPair], locale: Locale, target: Locale.Language
    ) async throws -> [Int: String] {
        translationCalls.append(pairs)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard !translationResults.isEmpty else { return [:] }
        return try translationResults.removeFirst().get()
    }

    func summarize(chunk: String, locale: Locale) async throws -> TranscriptSummary {
        TranscriptSummary(abstract: "sum(\(chunk.prefix(8)))", keyPoints: ["k"])
    }

    func combineSummaries(
        _ parts: [TranscriptSummary], locale: Locale
    ) async throws -> TranscriptSummary {
        TranscriptSummary(
            abstract: parts.map(\.abstract).joined(separator: " "),
            keyPoints: parts.flatMap(\.keyPoints))
    }

    func tableRows(chunk: String, locale: Locale) async throws -> [TranscriptTableRow] {
        [TranscriptTableRow(topic: "topic(\(chunk.prefix(8)))", detail: "detail")]
    }

    func rewrite(
        chunk: String, previousTail: String?, locale: Locale, style: RewriteStyle
    ) async throws -> String {
        "\(style.rawValue)(\(chunk.prefix(8)))"
    }
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
