import Foundation

/// One corrected string (source text or translation) from smart proofread,
/// tagged with the batch that produced it so a batch reverts as a unit.
nonisolated struct ProofreadCorrection: Sendable, Equatable {
    var text: String
    var batchID: UUID
}

/// Bookkeeping for one proofread run; `previousBoundaryID` is what revert
/// and total-failure rollback restore.
nonisolated struct ProofreadBatch: Sendable, Equatable {
    let id: UUID
    let previousBoundaryID: UUID?
    let boundaryID: UUID
}

/// Which proofread axes the user has enabled in Settings.
nonisolated struct ProofreadOptions: Sendable, Equatable {
    var transcription: Bool
    var translation: Bool

    var isEnabled: Bool { transcription || translation }
}

/// One entry's corrections from a finished chunk (nil axis = no change).
nonisolated struct ProofreadCorrectionUpdate: Sendable, Equatable {
    let segmentID: UUID
    var correctedText: String?
    var correctedTranslation: String?
}

/// Store-published run state; drives the glow and the ✦ button spinner.
nonisolated enum ProofreadActivity: Sendable, Equatable {
    case idle
    case running(batchID: UUID, chunksDone: Int, chunksTotal: Int)
}

/// How a proofread run ended; decides what happens to the boundary divider.
nonisolated enum ProofreadOutcome: Sendable, Equatable {
    case completed
    /// Partial results stay; the divider moves back to the last committed
    /// entry (or disappears when nothing was applied).
    case cancelled(rollbackBoundaryTo: UUID?, appliedAny: Bool)
    /// Nothing was applied; the divider returns to where it was.
    case failed(message: String)
}
