import AVFAudio
import Foundation
import Speech
import os

/// Live transcription built on the macOS 26+ `SpeechAnalyzer` pipeline.
///
/// One analyzer session per `start(consuming:)` call. Audio chunks are
/// converted to the analyzer's preferred format (via the official
/// `AnalyzerInputConverter` on macOS 27, manual `AVAudioConverter` on
/// macOS 26) and pumped into the analyzer's input sequence; transcriber
/// results are mapped to domain `TranscriptEvent`s.
actor SpeechAnalyzerTranscriber: TranscriptionProviding {
    /// Bounds on the analyzer's teardown calls. Both finalize AND
    /// `cancelAndFinishNow()` were observed to never return on a zero-audio
    /// session (iOS 26 beta, field log 2026-07-18), so every teardown await
    /// goes through `Deadline` and a hung analyzer is abandoned outright.
    private static let finalizeTimeout: Duration = .seconds(5)
    private static let cancelTimeout: Duration = .seconds(2)

    private let logger = BroadcastAudio.makeLogger(category: "Transcriber")
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var fedInputCount = 0

    func prepare(
        locale: Locale,
        onModelState: @escaping @Sendable (TranscriptionModelState) -> Void
    ) async throws -> Locale {
        onModelState(.checking)
        guard SpeechTranscriber.isAvailable else {
            onModelState(
                .failed(
                    String(
                        localized: "Speech-to-text is not available on this device.",
                        locale: AppLanguage.currentLocale())))
            throw TranscriptionError.unavailableOnDevice
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            onModelState(
                .failed(
                    String(
                        localized: "Locale \(locale.identifier) is not supported.", locale: AppLanguage.currentLocale())
                ))
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
                .failed(
                    String(
                        localized: "No transcription model for \(supported.identifier).",
                        locale: AppLanguage.currentLocale())))
            throw TranscriptionError.modelAssetsUnavailable
        @unknown default:
            onModelState(.failed(String(localized: "Unknown model asset state.", locale: AppLanguage.currentLocale())))
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
        fedInputCount = 0

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
        guard let analyzer else { return }
        // Detach immediately: once teardown starts, this instance never
        // touches the (possibly hung) analyzer again.
        self.analyzer = nil

        if fedInputCount == 0 {
            // Zero audio: finalize is known to hang; cancel — with a bound,
            // because the cancel hangs on such an analyzer too.
            logger.info("finish: no audio was fed, cancelling instead of finalizing")
            let returned = await Deadline.run(Self.cancelTimeout) {
                await analyzer.cancelAndFinishNow()
            }
            if !returned {
                logger.error("finish: cancelAndFinishNow did not return, abandoning the analyzer")
            }
            return
        }
        let finalized = await Deadline.run(Self.finalizeTimeout) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        if finalized {
            logger.info("finish: finalized after \(self.fedInputCount, privacy: .public) inputs")
        } else {
            logger.error("finish: finalize timed out, abandoning the analyzer")
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func cancel() async {
        pumpTask?.cancel()
        pumpTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        guard let analyzer else { return }
        self.analyzer = nil
        let returned = await Deadline.run(Self.cancelTimeout) {
            await analyzer.cancelAndFinishNow()
        }
        if !returned {
            logger.error("cancel: cancelAndFinishNow did not return, abandoning the analyzer")
        }
    }

    private func pump(
        audio: AsyncStream<AudioChunk>,
        converter: any PCMAnalyzerInputConverting,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        var conversionFailures = 0
        for await chunk in audio {
            if Task.isCancelled { break }
            do {
                for input in try converter.makeInputs(from: chunk) {
                    continuation.yield(input)
                    fedInputCount += 1
                }
            } catch {
                // One bad chunk must not end the session's entire input feed.
                conversionFailures += 1
                if conversionFailures == 1 || conversionFailures.isMultiple(of: 100) {
                    logger.error(
                        """
                        pump: conversion failed (\(error, privacy: .public)) \
                        count=\(conversionFailures, privacy: .public)
                        """)
                }
            }
        }
        continuation.finish()
        logger.info("pump exited after feeding \(self.fedInputCount, privacy: .public) inputs")
    }

    private func makeConverter(analyzerFormat: AVAudioFormat) -> any PCMAnalyzerInputConverting {
        if #available(macOS 27.0, iOS 27.0, *) {
            ModernAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        } else {
            LegacyAnalyzerInputConverter(targetFormat: analyzerFormat)
        }
    }
}
