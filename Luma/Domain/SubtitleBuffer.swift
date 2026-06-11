import CoreMedia
import Foundation

/// Pure, testable caption history: volatile hypothesis + ordered finalized
/// entries with translation back-fill and duplicate suppression.
nonisolated struct SubtitleBuffer: Sendable, Equatable {
    private(set) var entries: [SubtitleEntry] = []
    private(set) var volatileText: AttributedString?
    private(set) var volatileRange: CMTimeRange?

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

    mutating func clear() {
        entries.removeAll()
        volatileText = nil
        volatileRange = nil
    }
}
