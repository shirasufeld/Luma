#if os(iOS)
import Foundation

/// iOS transcript exporter. The macOS counterpart (`TranscriptExportService`)
/// uses `NSSavePanel`; on iOS the document is written and shared through a
/// document picker / share sheet.
///
/// M1 placeholder; the real share flow is implemented in M3.
@MainActor
final class DocumentExportService: TranscriptExporting {

    func export(
        entries: [SubtitleEntry],
        format: TranscriptExportFormat
    ) async throws -> URL? {
        nil
    }
}
#endif
