import CoreMedia
import Foundation

/// Export formats for the caption history.
nonisolated enum TranscriptExportFormat: String, Sendable, CaseIterable {
    case text
    case srt

    var fileExtension: String {
        switch self {
        case .text: "txt"
        case .srt: "srt"
        }
    }
}

/// Pure serialization of subtitle entries to TXT and SRT. Timecodes are
/// session-relative, derived from each segment's audio time range.
nonisolated enum SRTFormatter {

    static func document(
        entries: [SubtitleEntry],
        format: TranscriptExportFormat,
        includeTranslations: Bool = true
    ) -> String {
        switch format {
        case .text: textDocument(entries: entries, includeTranslations: includeTranslations)
        case .srt: srtDocument(entries: entries, includeTranslations: includeTranslations)
        }
    }

    static func textDocument(entries: [SubtitleEntry], includeTranslations: Bool = true) -> String {
        entries.map { entry in
            var lines = [entry.segment.plainText]
            if includeTranslations, case .translated(let translation) = entry.translation {
                lines.append(translation)
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func srtDocument(entries: [SubtitleEntry], includeTranslations: Bool = true) -> String {
        entries.enumerated().map { index, entry in
            let start = clampedSeconds(entry.segment.range.start)
            var end = clampedSeconds(entry.segment.range.end)
            // SRT requires end > start; degenerate ranges get a minimum hold.
            if end <= start {
                end = start + 1.5
            }
            var lines = [
                "\(index + 1)",
                "\(timecode(start)) --> \(timecode(end))",
                entry.segment.plainText,
            ]
            if includeTranslations, case .translated(let translation) = entry.translation {
                lines.append(translation)
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
    }

    /// `HH:MM:SS,mmm` (SRT uses a comma before milliseconds).
    static func timecode(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(
            format: "%02d:%02d:%02d,%03d", hours, minutes, secondsPart, milliseconds)
    }

    private static func clampedSeconds(_ time: CMTime) -> TimeInterval {
        guard time.isNumeric else { return 0 }
        return max(0, time.seconds)
    }
}
