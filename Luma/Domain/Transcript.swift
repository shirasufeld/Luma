import CoreMedia
import Foundation

/// A finalized piece of transcribed speech with its position on the session's
/// audio timeline.
nonisolated struct TranscriptSegment: Sendable, Equatable, Identifiable {
    let id: UUID
    /// Rich text from the transcriber (may carry confidence/time attributes).
    var text: AttributedString
    /// Position of this segment on the audio timeline.
    var range: CMTimeRange
    /// Wall-clock time when the segment was finalized (used for latency stats).
    var finalizedAt: Date

    var plainText: String {
        String(text.characters)
    }

    init(
        id: UUID = UUID(),
        text: AttributedString,
        range: CMTimeRange,
        finalizedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.range = range
        self.finalizedAt = finalizedAt
    }
}

/// Events emitted by the transcription pipeline.
nonisolated enum TranscriptEvent: Sendable {
    /// In-progress hypothesis that later results will revise or replace.
    case volatile(text: AttributedString, range: CMTimeRange)
    /// Final result for a stretch of audio; safe to translate and export.
    case finalized(TranscriptSegment)
}

/// State of the on-device transcription model assets for the active locale.
nonisolated enum TranscriptionModelState: Sendable, Equatable {
    case checking
    /// Assets are being downloaded; progress is 0...1 when known.
    case downloading(progress: Double?)
    case ready
    case failed(String)
}

/// Trade-off preset for live translation.
nonisolated enum TranslationMode: String, Sendable, CaseIterable, Identifiable {
    /// Slower, sentence-accurate output (high-fidelity models when available).
    case accurate
    /// Lower-latency output using the faster traditional models.
    case realtime

    var id: String { rawValue }
}

/// Errors surfaced by the transcription pipeline.
nonisolated enum TranscriptionError: Error, Equatable {
    case unavailableOnDevice
    case unsupportedLocale(Locale)
    case modelAssetsUnavailable
    case noCompatibleAudioFormat
    case notPrepared
}
