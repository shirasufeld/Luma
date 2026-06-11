import Foundation

/// Saves the caption history to a user-chosen file.
@MainActor
protocol TranscriptExporting {
    /// Presents a save panel and writes the document. Returns the written
    /// URL, or nil when the user cancels.
    func export(
        entries: [SubtitleEntry],
        format: TranscriptExportFormat
    ) async throws -> URL?
}
