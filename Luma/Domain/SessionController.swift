import CoreMedia
import Foundation

/// Orchestrates one captioning session: permissions → model preparation →
/// audio capture → transcription events → store updates. Translation of
/// finalized segments hooks in downstream of the event loop.
actor SessionController {
    private let store: SessionStore
    private let capabilities: any CapabilityChecking
    private let transcription: any TranscriptionProviding
    private let translation: any TranslationProviding
    private let audioProviderFactory: @Sendable (AudioInputKind) -> any AudioInputProviding

    private var audioProvider: (any AudioInputProviding)?
    private var eventTask: Task<Void, Never>?
    private var state: SessionState = .idle

    // Translation runs on its own serial queue so slow translations never
    // stall the transcript event loop.
    private var translationReady = false
    private var translationQueue: AsyncStream<TranscriptSegment>.Continuation?
    private var translationWorker: Task<Void, Never>?

    // Latency estimation: wall-clock anchor of audio time zero, with pauses
    // subtracted so the audio timeline and wall clock stay comparable.
    private var wallClockStart: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBegan: Date?

    init(
        store: SessionStore,
        capabilities: any CapabilityChecking,
        transcription: any TranscriptionProviding,
        translation: any TranslationProviding,
        audioProviderFactory: @escaping @Sendable (AudioInputKind) -> any AudioInputProviding
    ) {
        self.store = store
        self.capabilities = capabilities
        self.transcription = transcription
        self.translation = translation
        self.audioProviderFactory = audioProviderFactory
    }

    // MARK: - Controls

    func start(languagePair: LanguagePair, inputKind: AudioInputKind) async {
        guard state == .idle else { return }
        state = .preparing
        await store.sessionStateChanged(.preparing)

        do {
            if inputKind == .microphone {
                var permission = capabilities.microphonePermission()
                if permission == .notDetermined {
                    permission = await capabilities.requestMicrophonePermission()
                }
                guard permission == .granted else {
                    throw SessionError.microphoneAccessDenied
                }
            }

            let store = self.store
            let resolved = try await transcription.prepare(locale: languagePair.transcriptionLocale) {
                modelState in
                Task { @MainActor in
                    store.modelStateChanged(modelState)
                }
            }
            await store.transcriptionDidResolve(locale: resolved)

            let availability = await translation.setLanguagePair(
                source: languagePair.translationSource,
                target: languagePair.translationTarget)
            translationReady = availability == .installed
            await store.translationAvailabilityChanged(availability)
            if translationReady {
                startTranslationWorker()
            }

            let provider = audioProviderFactory(inputKind)
            audioProvider = provider
            let audioStream = try await provider.start()
            let events = try await transcription.start(consuming: audioStream)

            wallClockStart = Date()
            pausedAccumulated = 0
            pauseBegan = nil
            state = .running
            await store.sessionStateChanged(.running)

            eventTask = Task {
                await self.consume(events)
            }
        } catch {
            await failSession(with: error)
        }
    }

    func pause() async {
        guard state == .running else { return }
        await audioProvider?.pause()
        pauseBegan = Date()
        state = .paused
        await store.sessionStateChanged(.paused)
    }

    func resume() async {
        guard state == .paused else { return }
        do {
            try await audioProvider?.resume()
            if let pauseBegan {
                pausedAccumulated += Date().timeIntervalSince(pauseBegan)
            }
            pauseBegan = nil
            state = .running
            await store.sessionStateChanged(.running)
        } catch {
            await failSession(with: error)
        }
    }

    func stop() async {
        guard state == .running || state == .paused || state == .preparing else { return }
        state = .stopping
        await store.sessionStateChanged(.stopping)

        await audioProvider?.stop()
        audioProvider = nil
        do {
            try await transcription.finish()
        } catch {
            await transcription.cancel()
        }
        // Let the event task drain remaining finalized results.
        _ = await eventTask?.value
        eventTask = nil

        // Then let queued translations finish.
        translationQueue?.finish()
        translationQueue = nil
        _ = await translationWorker?.value
        translationWorker = nil

        state = .idle
        await store.sessionStateChanged(.idle)
    }

    func clearTranscript() async {
        await store.clearTranscript()
    }

    // MARK: - Event loop

    private func consume(_ events: AsyncThrowingStream<TranscriptEvent, any Error>) async {
        do {
            for try await event in events {
                switch event {
                case .volatile(let text, let range):
                    await store.applyVolatile(
                        text: text, range: range, latency: estimatedLatency(toAudioEnd: range.end))
                case .finalized(let segment):
                    let appended = await store.applyFinalized(
                        segment, latency: estimatedLatency(toAudioEnd: segment.range.end))
                    if appended {
                        await translateIfPossible(segment)
                    }
                }
            }
        } catch {
            await failSession(with: error)
        }
    }

    private func translateIfPossible(_ segment: TranscriptSegment) async {
        guard translationReady, let translationQueue else {
            await store.applyTranslation(segmentID: segment.id, state: .unavailable)
            return
        }
        translationQueue.yield(segment)
    }

    private func startTranslationWorker() {
        let (queue, continuation) = AsyncStream.makeStream(
            of: TranscriptSegment.self, bufferingPolicy: .unbounded)
        translationQueue = continuation
        translationWorker = Task {
            await self.runTranslationWorker(queue: queue)
        }
    }

    private func runTranslationWorker(queue: AsyncStream<TranscriptSegment>) async {
        for await segment in queue {
            do {
                let translated = try await translation.translate(segment.plainText)
                await store.applyTranslation(segmentID: segment.id, state: .translated(translated))
            } catch is CancellationError {
                break
            } catch {
                await store.applyTranslation(
                    segmentID: segment.id, state: .failed(error.localizedDescription))
            }
        }
    }

    private func estimatedLatency(toAudioEnd end: CMTime) -> TimeInterval? {
        guard let wallClockStart, end.isNumeric else { return nil }
        let elapsedWall = Date().timeIntervalSince(wallClockStart) - pausedAccumulated
        let latency = elapsedWall - end.seconds
        return latency >= 0 ? latency : nil
    }

    private func failSession(with error: any Error) async {
        await audioProvider?.stop()
        audioProvider = nil
        await transcription.cancel()
        eventTask?.cancel()
        eventTask = nil
        translationQueue?.finish()
        translationQueue = nil
        translationWorker?.cancel()
        translationWorker = nil
        state = .idle
        await store.sessionFailed(Self.message(for: error))
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case SessionError.microphoneAccessDenied:
            return "Microphone access is denied. Enable it in System Settings > Privacy & Security."
        case TranscriptionError.unavailableOnDevice:
            return "Speech-to-text is not available on this device."
        case TranscriptionError.unsupportedLocale(let locale):
            return "Transcription does not support \(locale.identifier)."
        case TranscriptionError.modelAssetsUnavailable:
            return "Transcription model assets could not be installed."
        case TranscriptionError.noCompatibleAudioFormat:
            return "No compatible audio format for the transcriber."
        default:
            return error.localizedDescription
        }
    }
}

nonisolated enum SessionError: Error, Equatable {
    case microphoneAccessDenied
}
