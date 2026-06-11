import AppKit
import Foundation
import UniformTypeIdentifiers

/// NSSavePanel-backed exporter writing SRTFormatter output as UTF-8.
@MainActor
final class TranscriptExportService: TranscriptExporting {

    func export(
        entries: [SubtitleEntry],
        format: TranscriptExportFormat
    ) async throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName(format: format)
        if let contentType = contentType(for: format) {
            panel.allowedContentTypes = [contentType]
        }

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        let document = SRTFormatter.document(entries: entries, format: format)
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func defaultFileName(format: TranscriptExportFormat) -> String {
        let stamp = Date().formatted(
            .iso8601
                .year().month().day()
                .timeSeparator(.omitted)
                .time(includingFractionalSeconds: false)
        )
        .replacingOccurrences(of: ":", with: "")
        return "Luma Transcript \(stamp).\(format.fileExtension)"
    }

    private func contentType(for format: TranscriptExportFormat) -> UTType? {
        switch format {
        case .text: .plainText
        case .srt: UTType(filenameExtension: "srt", conformingTo: .text)
        }
    }
}
