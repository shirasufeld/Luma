#if os(iOS)
import Foundation
import UIKit

/// iOS transcript exporter. The macOS counterpart (`TranscriptExportService`)
/// uses `NSSavePanel`; on iOS the document is written to a temporary file and
/// handed to a `UIDocumentPickerViewController` so the user can save it into
/// Files (or any document provider).
@MainActor
final class DocumentExportService: TranscriptExporting {

    /// Retains the picker delegate for the duration of one presentation.
    private var activeDelegate: ExportPickerDelegate?

    func export(
        entries: [SubtitleEntry],
        format: TranscriptExportFormat
    ) async throws -> URL? {
        let document = SRTFormatter.document(entries: entries, format: format)
        let fileURL = URL.temporaryDirectory.appending(path: defaultFileName(format: format))
        try document.write(to: fileURL, atomically: true, encoding: .utf8)
        return await present(exporting: fileURL)
    }

    /// Presents the export picker and resumes with the saved URL, or nil if the
    /// user cancels or no presentation context is available.
    private func present(exporting url: URL) async -> URL? {
        guard let presenter = Self.topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            let delegate = ExportPickerDelegate { [weak self] result in
                self?.activeDelegate = nil
                continuation.resume(returning: result)
            }
            activeDelegate = delegate
            picker.delegate = delegate
            presenter.present(picker, animated: true)
        }
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

    /// Finds the front-most view controller to present from.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard
            var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Bridges `UIDocumentPickerViewController` callbacks to a single completion.
private final class ExportPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?) -> Void

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        completion(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}
#endif
