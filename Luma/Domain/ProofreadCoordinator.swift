import Foundation

/// Runs one smart-proofread batch at a time: snapshots eligible entries from
/// the store, chunks them within the model's context budget, and back-fills
/// corrections by segment UUID while live transcription keeps appending.
///
/// Concurrency shape mirrors the translation worker in `SessionController`:
/// serial work off the main actor, results landing through main-actor store
/// methods that address entries by UUID — so late results can never corrupt
/// a cleared or advancing transcript.
actor ProofreadCoordinator {
    private let store: SessionStore
    private let intelligence: any IntelligenceProviding
    /// Estimated-token budget per chunk. Instructions (~250) + sparse
    /// corrections output stay well inside the 26-era ~4096 window;
    /// underestimates are caught by error-driven bisect.
    private let inputBudget: Int
    private var runTask: Task<Void, Never>?

    init(
        store: SessionStore,
        intelligence: any IntelligenceProviding,
        inputBudget: Int = 1400
    ) {
        self.store = store
        self.intelligence = intelligence
        self.inputBudget = inputBudget
    }

    /// Starts a batch over everything after the current boundary. No-op when
    /// a run is active, nothing is eligible, or the model can't serve the
    /// transcript locale.
    func startProofread(
        options: ProofreadOptions, locale: Locale, target: Locale.Language?
    ) async {
        guard runTask == nil, options.isEnabled else { return }
        guard await intelligence.availability(for: locale) == .available else { return }
        var effective = options
        if effective.translation {
            if let target {
                effective.translation = await intelligence.supportsLanguage(target)
            } else {
                effective.translation = false
            }
        }
        guard effective.isEnabled else { return }
        guard let (entries, context, batch) = await store.beginProofread() else { return }
        let resolved = effective
        runTask = Task {
            await self.run(
                entries: entries, context: context, batch: batch,
                options: resolved, locale: locale, target: target)
        }
    }

    /// Cancels and *waits* for the run's rollback bookkeeping, so callers
    /// (new session, clear) never race an in-flight apply.
    func cancelActiveRun() async {
        runTask?.cancel()
        await runTask?.value
        runTask = nil
    }

    /// Single-level undo of the last batch.
    func revertLast() async {
        guard runTask == nil else { return }
        await store.revertLastProofread()
    }

    // MARK: - Run

    private func run(
        entries: [SubtitleEntry], context: String?, batch: ProofreadBatch,
        options: ProofreadOptions, locale: Locale, target: Locale.Language?
    ) async {
        defer { runTask = nil }

        let translationByID: [UUID: String] = entries.reduce(into: [:]) { result, entry in
            if case .translated(let text) = entry.translation { result[entry.id] = text }
        }
        var remaining = IntelligenceChunker.chunks(
            entries: entries.map { (id: $0.id, text: $0.displayText) },
            budget: inputBudget, initialContext: context)
        var totalPlanned = remaining.count
        await store.proofreadChunksPlanned(totalPlanned, batchID: batch.id)

        var appliedAny = false
        var anyChunkSucceeded = false
        var lastCommittedID = batch.previousBoundaryID
        var abortMessage: String?

        while !remaining.isEmpty, !Task.isCancelled, abortMessage == nil {
            let chunk = remaining.removeFirst()
            do {
                let updates = try await processWithRetry(
                    chunk: chunk, options: options, locale: locale,
                    target: target, translationByID: translationByID)
                if Task.isCancelled { break }
                await store.applyProofreadCorrections(updates, batchID: batch.id)
                await store.proofreadChunkFinished(batchID: batch.id)
                anyChunkSucceeded = true
                if !updates.isEmpty { appliedAny = true }
                lastCommittedID = chunk.entryIDs.last ?? lastCommittedID
            } catch is CancellationError {
                break
            } catch IntelligenceError.contextWindowExceeded {
                if let (first, second) = IntelligenceChunker.bisect(chunk) {
                    remaining.insert(contentsOf: [first, second], at: 0)
                    totalPlanned += 1
                    await store.proofreadChunksPlanned(totalPlanned, batchID: batch.id)
                } else {
                    // A single sentence beyond the window: leave it as-is.
                    await store.proofreadChunkFinished(batchID: batch.id)
                }
            } catch IntelligenceError.unsupportedLanguage {
                abortMessage = String(
                    localized: "Apple Intelligence does not support this language yet.",
                    locale: AppLanguage.currentLocale())
            } catch {
                // Guardrail, refusal, decoding, repeated rate limit: this
                // chunk stays untouched; the rest of the batch continues.
                await store.proofreadChunkFinished(batchID: batch.id)
            }
        }

        if Task.isCancelled {
            await store.finishProofread(
                batchID: batch.id,
                outcome: .cancelled(rollbackBoundaryTo: lastCommittedID, appliedAny: appliedAny))
        } else if let abortMessage {
            await store.finishProofread(batchID: batch.id, outcome: .failed(message: abortMessage))
        } else if anyChunkSucceeded {
            await store.finishProofread(batchID: batch.id, outcome: .completed)
        } else {
            await store.finishProofread(
                batchID: batch.id,
                outcome: .failed(
                    message: String(
                        localized: "Proofreading didn't complete. Try again in a moment.",
                        locale: AppLanguage.currentLocale())))
        }
    }

    private func processWithRetry(
        chunk: IntelligenceChunker.Chunk, options: ProofreadOptions,
        locale: Locale, target: Locale.Language?, translationByID: [UUID: String]
    ) async throws -> [ProofreadCorrectionUpdate] {
        do {
            return try await process(
                chunk: chunk, options: options, locale: locale,
                target: target, translationByID: translationByID)
        } catch IntelligenceError.rateLimited {
            try? await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            return try await process(
                chunk: chunk, options: options, locale: locale,
                target: target, translationByID: translationByID)
        }
    }

    /// Pass A corrects the source sentences; pass B reviews translations
    /// against the *corrected* sources. Entries whose translation was still
    /// pending (or failed/off) at snapshot time get pass A only.
    private func process(
        chunk: IntelligenceChunker.Chunk, options: ProofreadOptions,
        locale: Locale, target: Locale.Language?, translationByID: [UUID: String]
    ) async throws -> [ProofreadCorrectionUpdate] {
        var correctedSource: [Int: String] = [:]
        if options.transcription {
            correctedSource = try await intelligence.proofreadTranscription(
                sentences: chunk.sentences, context: chunk.contextSentence, locale: locale)
        }

        var correctedTranslations: [Int: String] = [:]
        if options.translation, let target {
            var sentenceIndices: [Int] = []
            var pairs: [ProofreadPair] = []
            for (offset, id) in chunk.entryIDs.enumerated() {
                guard let translation = translationByID[id] else { continue }
                let index = offset + 1
                sentenceIndices.append(index)
                pairs.append(
                    ProofreadPair(
                        source: correctedSource[index] ?? chunk.sentences[offset],
                        translation: translation))
            }
            if !pairs.isEmpty {
                let corrected = try await intelligence.proofreadTranslation(
                    pairs: pairs, locale: locale, target: target)
                for (pairOffset, sentenceIndex) in sentenceIndices.enumerated() {
                    if let text = corrected[pairOffset + 1] {
                        correctedTranslations[sentenceIndex] = text
                    }
                }
            }
        }

        return chunk.entryIDs.enumerated().compactMap { offset, id in
            let source = correctedSource[offset + 1]
            let translation = correctedTranslations[offset + 1]
            guard source != nil || translation != nil else { return nil }
            return ProofreadCorrectionUpdate(
                segmentID: id, correctedText: source, correctedTranslation: translation)
        }
    }
}
