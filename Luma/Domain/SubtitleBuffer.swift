import CoreMedia
import Foundation

/// Pure, testable caption history: volatile hypothesis + ordered finalized
/// entries with translation back-fill and duplicate suppression.
nonisolated struct SubtitleBuffer: Sendable, Equatable {
    private(set) var entries: [SubtitleEntry] = []
    private(set) var volatileText: AttributedString?
    private(set) var volatileRange: CMTimeRange?
    /// Last entry covered by smart proofread; the divider in the transcript.
    private(set) var proofreadBoundaryID: UUID?
    /// Single-level revert target: the most recent proofread batch.
    private(set) var lastProofreadBatch: ProofreadBatch?

    /// Number of recent entries compared when suppressing re-finalized
    /// duplicates of the same audio range.
    private static let dedupeWindow = 8

    mutating func applyVolatile(text: AttributedString, range: CMTimeRange) {
        volatileText = text
        volatileRange = range
    }

    /// Appends a finalized segment unless it's empty or duplicates recent
    /// content (same time range and text). Returns true when appended.
    @discardableResult
    mutating func applyFinalized(_ segment: TranscriptSegment) -> Bool {
        // A finalized result supersedes the running hypothesis either way.
        volatileText = nil
        volatileRange = nil

        let plain = segment.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return false }

        let isDuplicate = entries.suffix(Self.dedupeWindow).contains { existing in
            existing.segment.id == segment.id
                || (existing.segment.range == segment.range
                    && existing.segment.plainText == segment.plainText)
        }
        guard !isDuplicate else { return false }

        entries.append(SubtitleEntry(segment: segment))
        return true
    }

    mutating func applyTranslation(segmentID: UUID, state: TranslationState) {
        guard let index = entries.lastIndex(where: { $0.id == segmentID }) else { return }
        entries[index].translation = state
    }

    // MARK: - Smart proofread

    /// Entries eligible for the next proofread run: everything after the
    /// current boundary (all entries when no boundary is set).
    var entriesAfterBoundary: [SubtitleEntry] {
        guard let proofreadBoundaryID,
            let index = entries.lastIndex(where: { $0.id == proofreadBoundaryID })
        else { return entries }
        return Array(entries[(index + 1)...])
    }

    /// Starts a batch: moves the divider to the batch boundary and makes
    /// this batch the single-level revert target.
    mutating func beginProofreadBatch(_ batch: ProofreadBatch) {
        proofreadBoundaryID = batch.boundaryID
        lastProofreadBatch = batch
    }

    /// Back-fills one chunk's corrections. Stale batches are refused and
    /// vanished entries skipped, so late results can never corrupt state —
    /// the same UUID-addressed discipline as `applyTranslation`.
    mutating func applyProofread(_ updates: [ProofreadCorrectionUpdate], batchID: UUID) {
        guard batchID == lastProofreadBatch?.id else { return }
        for update in updates {
            guard let index = entries.lastIndex(where: { $0.id == update.segmentID })
            else { continue }
            if let text = update.correctedText {
                entries[index].correctedText = ProofreadCorrection(text: text, batchID: batchID)
            }
            if let translation = update.correctedTranslation {
                entries[index].correctedTranslation = ProofreadCorrection(
                    text: translation, batchID: batchID)
            }
        }
    }

    /// Cancelled run: the divider moves back to the last committed entry;
    /// corrections already applied stay (still revertable as a batch).
    mutating func rollbackProofreadBoundary(to id: UUID?, batchID: UUID) {
        guard batchID == lastProofreadBatch?.id else { return }
        proofreadBoundaryID = id
    }

    /// Ends a batch that applied nothing: the divider returns to where it
    /// was and there is nothing left to revert.
    mutating func abandonProofreadBatch(_ batchID: UUID) {
        guard let batch = lastProofreadBatch, batch.id == batchID else { return }
        proofreadBoundaryID = batch.previousBoundaryID
        lastProofreadBatch = nil
    }

    /// Single-level undo: removes the last batch's corrections and returns
    /// the divider to where it was before that batch.
    mutating func revertLastProofread() {
        guard let batch = lastProofreadBatch else { return }
        for index in entries.indices {
            if entries[index].correctedText?.batchID == batch.id {
                entries[index].correctedText = nil
            }
            if entries[index].correctedTranslation?.batchID == batch.id {
                entries[index].correctedTranslation = nil
            }
        }
        proofreadBoundaryID = batch.previousBoundaryID
        lastProofreadBatch = nil
    }

    mutating func clear() {
        entries.removeAll()
        volatileText = nil
        volatileRange = nil
        proofreadBoundaryID = nil
        lastProofreadBatch = nil
    }
}
