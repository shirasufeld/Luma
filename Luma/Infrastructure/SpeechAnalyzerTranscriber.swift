import AVFAudio
import Foundation
import Speech

/// Live transcription built on the macOS 26+ `SpeechAnalyzer` pipeline.
///
/// One analyzer session per `start(consuming:)` call. Audio chunks are
/// converted to the analyzer's preferred format (via the official
/// `AnalyzerInputConverter` on macOS 27, manual `AVAudioConverter` on
/// macOS 26) and pumped into the analyzer's input sequence; transcriber
/// results are mapped to domain `TranscriptEvent`s.
actor SpeechAnalyzerTranscriber: TranscriptionProviding {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?

    func prepare(
        locale: Locale,
        onModelState: @escaping @Sendable (TranscriptionModelState) -> Void
    ) async throws -> Locale {
        onModelState(.checking)
        guard SpeechTranscriber.isAvailable else {
            onModelState(
                .failed(String(localized: "Speech-to-text is not available on this device.")))
            throw TranscriptionError.unavailableOnDevice
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            onModelState(.failed(String(localized: "Locale \(locale.identifier) is not supported.")))
            throw TranscriptionError.unsupportedLocale(locale)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])

        // Best-effort: pin assets for this locale. Failure here is not fatal;
        // a real problem surfaces from the installation request below.
        _ = try? await AssetInventory.reserve(locale: supported)

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .supported, .downloading:
            // TODO: surface AssetInstallationRequest.progress once Progress
            // observation is wired up; beta-1 keeps this indeterminate.
            onModelState(.downloading(progress: nil))
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            onModelState(
                .failed(String(localized: "No transcription model for \(supported.identifier).")))
            throw TranscriptionError.modelAssetsUnavailable
        @unknown default:
            onModelState(.failed(String(localized: "Unknown model asset state.")))
            throw TranscriptionError.modelAssetsUnavailable
        }

        self.transcriber = transcriber
        onModelState(.ready)
        return supported
    }

    func start(
        consuming audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        guard let transcriber else {
            throw TranscriptionError.notPrepared
        }
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
        else {
            throw TranscriptionError.noCompatibleAudioFormat
        }

        let converter = makeConverter(analyzerFormat: analyzerFormat)
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // Pump: capture stream -> format conversion -> analyzer input.
        // Referencing `self` keeps the task (and the non-Sendable converter)
        // on this actor.
        pumpTask = Task {
            await self.pump(audio: audio, converter: converter, into: inputContinuation)
        }

        let results = transcriber.results
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        if result.isFinal {
                            continuation.yield(
                                .finalized(
                                    TranscriptSegment(text: result.text, range: result.range)))
                        } else {
                            continuation.yield(.volatile(text: result.text, range: result.range))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func finish() async throws {
        pumpTask?.cancel()
        pumpTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    func cancel() async {
        pumpTask?.cancel()
        pumpTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    private func pump(
        audio: AsyncStream<AudioChunk>,
        converter: any PCMAnalyzerInputConverting,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        for await chunk in audio {
            if Task.isCancelled { break }
            guard let inputs = try? converter.makeInputs(from: chunk) else { break }
            for input in inputs {
                continuation.yield(input)
            }
        }
        continuation.finish()
    }

    private func makeConverter(analyzerFormat: AVAudioFormat) -> any PCMAnalyzerInputConverting {
        if #available(macOS 27.0, iOS 27.0, *) {
            ModernAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        } else {
            LegacyAnalyzerInputConverter(targetFormat: analyzerFormat)
        }
    }
}
