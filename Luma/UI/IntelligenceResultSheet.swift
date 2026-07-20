import SwiftUI
import UniformTypeIdentifiers

/// Which rewrite the Apple Intelligence menu launched.
nonisolated enum IntelligenceOperation: String, Identifiable, Sendable {
    case summary
    case reformat
    case rewrite
    case friendly
    case professional
    case concise
    case list
    case table

    var id: String { rawValue }

    /// The prose pipeline style for map-only operations; nil for the
    /// map-reduce summary and the table.
    var proseStyle: RewriteStyle? {
        switch self {
        case .reformat: .reformat
        case .rewrite: .rewrite
        case .friendly: .friendly
        case .professional: .professional
        case .concise: .concise
        case .list: .bulletList
        case .summary, .table: nil
        }
    }
}

/// Drives one rewrite run over a value snapshot of the transcript. The sheet
/// owns the model; dismissing cancels the run. Chunked map-reduce keeps every
/// request inside the on-device context window.
@MainActor
@Observable
final class IntelligenceSheetModel {
    enum Phase: Equatable {
        case working(step: Int, total: Int)
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .working(step: 0, total: 0)
    private(set) var summary: TranscriptSummary?
    private(set) var rows: [TranscriptTableRow] = []
    private(set) var reformatted = ""

    let operation: IntelligenceOperation
    private let texts: [String]
    private let locale: Locale
    private let intelligence: any IntelligenceProviding
    private var task: Task<Void, Never>?

    init(
        operation: IntelligenceOperation,
        entries: [SubtitleEntry],
        locale: Locale,
        intelligence: any IntelligenceProviding
    ) {
        self.operation = operation
        // Corrected text feeds the rewrite; translations stay out (mixed
        // languages confuse the small model and burn budget).
        self.texts = entries.map(\.displayText)
        self.locale = locale
        self.intelligence = intelligence
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Copy/export payload; "- " bullets and pipe tables read fine as both
    /// .txt and .md.
    var resultText: String {
        switch operation {
        case .summary:
            guard let summary else { return "" }
            return summary.abstract + "\n\n"
                + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n")
        case .table:
            let header = String(localized: "Topic", locale: AppLanguage.currentLocale())
            let detail = String(localized: "Detail", locale: AppLanguage.currentLocale())
            return "| \(header) | \(detail) |\n| --- | --- |\n"
                + rows.map { "| \($0.topic) | \($0.detail) |" }.joined(separator: "\n")
        case .reformat, .rewrite, .friendly, .professional, .concise, .list:
            return reformatted
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    func retry() {
        task?.cancel()
        task = nil
        phase = .working(step: 0, total: 0)
        summary = nil
        rows = []
        reformatted = ""
        start()
    }

    private func run() async {
        let chunks = IntelligenceChunker.chunks(
            entries: texts.map { (id: UUID(), text: $0) },
            budget: 2600, initialContext: nil)
        do {
            switch operation {
            case .summary:
                try await runSummary(chunks: chunks)
            case .table:
                try await runTable(chunks: chunks)
            case .reformat, .rewrite, .friendly, .professional, .concise, .list:
                try await runProse(chunks: chunks, style: operation.proseStyle ?? .reformat)
            }
        } catch is CancellationError {
            // Sheet dismissed; nothing to publish.
        } catch {
            phase = .failed(Self.failureMessage(for: error))
        }
    }

    private func runSummary(chunks: [IntelligenceChunker.Chunk]) async throws {
        var drafts: [TranscriptSummary] = []
        var skipped = false
        phase = .working(step: 0, total: chunks.count + 1)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            phase = .working(step: index + 1, total: chunks.count + 1)
            do {
                drafts.append(
                    try await intelligence.summarize(
                        chunk: chunk.sentences.joined(separator: "\n"), locale: locale))
            } catch IntelligenceError.guardrailViolation, IntelligenceError.refusal {
                skipped = true
            }
        }
        guard var merged = drafts.first else {
            throw IntelligenceError.guardrailViolation
        }
        phase = .working(step: chunks.count + 1, total: chunks.count + 1)
        if drafts.count > 1 {
            merged = try await intelligence.combineSummaries(drafts, locale: locale)
        }
        if skipped {
            merged.keyPoints.append(
                String(
                    localized: "Some sections could not be processed.",
                    locale: AppLanguage.currentLocale()))
        }
        summary = merged
        phase = .finished
    }

    private func runTable(chunks: [IntelligenceChunker.Chunk]) async throws {
        phase = .working(step: 0, total: chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            phase = .working(step: index + 1, total: chunks.count)
            do {
                rows.append(
                    contentsOf: try await intelligence.tableRows(
                        chunk: chunk.sentences.joined(separator: "\n"), locale: locale))
            } catch IntelligenceError.guardrailViolation, IntelligenceError.refusal {
                continue
            }
        }
        guard !rows.isEmpty else { throw IntelligenceError.guardrailViolation }
        phase = .finished
    }

    private func runProse(chunks: [IntelligenceChunker.Chunk], style: RewriteStyle) async throws {
        phase = .working(step: 0, total: chunks.count)
        var tail: String?
        let separator = style == .bulletList ? "\n" : "\n\n"
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            phase = .working(step: index + 1, total: chunks.count)
            let joined = chunk.sentences.joined(separator: "\n")
            var piece: String
            do {
                piece = try await intelligence.rewrite(
                    chunk: joined, previousTail: tail, locale: locale, style: style)
            } catch IntelligenceError.guardrailViolation, IntelligenceError.refusal {
                // Never drop the user's content: pass the chunk through
                // untouched instead.
                piece = joined
            }
            reformatted += (reformatted.isEmpty ? "" : separator) + piece
            tail = style == .bulletList ? nil : String(piece.suffix(200))
        }
        phase = .finished
    }

    private static func failureMessage(for error: any Error) -> String {
        switch error {
        case IntelligenceError.unavailable:
            String(
                localized: "Apple Intelligence is not available right now.",
                locale: AppLanguage.currentLocale())
        case IntelligenceError.unsupportedLanguage:
            String(
                localized: "Apple Intelligence does not support this language yet.",
                locale: AppLanguage.currentLocale())
        default:
            String(
                localized: "Generation didn't complete. Try again in a moment.",
                locale: AppLanguage.currentLocale())
        }
    }
}

/// Result card for Summary / Reformat: quiet container, processing glow
/// while generating, copy/export once finished. The transcript itself is
/// never touched.
struct IntelligenceResultSheet: View {
    @State private var model: IntelligenceSheetModel
    @State private var isExporting = false
    @State private var exportType: UTType = .plainText
    @Environment(\.dismiss) private var dismiss

    /// Sheets get a fresh presentation environment, so the in-app language
    /// override must be re-applied here (same as the Settings sheet) — the
    /// card must follow the user's chosen app language, not the system's.
    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.systemValue

    init(
        operation: IntelligenceOperation,
        entries: [SubtitleEntry],
        locale: Locale,
        intelligence: any IntelligenceProviding
    ) {
        _model = State(
            initialValue: IntelligenceSheetModel(
                operation: operation, entries: entries, locale: locale,
                intelligence: intelligence))
    }

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .aiProcessingGlow(model.isWorking)
                .padding(8)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if model.phase == .finished {
                        ToolbarItemGroup {
                            Button("Copy", systemImage: "doc.on.doc") { copyResult() }
                            Menu("Export", systemImage: "square.and.arrow.up") {
                                Button("Plain Text…") { export(as: .plainText) }
                                Button("Markdown…") { export(as: markdownType) }
                            }
                            .menuIndicator(.hidden)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 480)
        #endif
        .appLanguage(appLanguageRaw)
        .task { model.start() }
        .onDisappear { model.cancel() }
        .fileExporter(
            isPresented: $isExporting,
            document: TextExportDocument(text: model.resultText),
            contentType: exportType,
            defaultFilename: defaultFilename
        ) { _ in }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .working(let step, let total):
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                if total > 1 {
                    Text("Part \(step) of \(total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                partialResult
            }
        case .finished:
            ScrollView {
                finishedResult
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry") { model.retry() }
            }
        }
    }

    /// Prose operations stream chunk-by-chunk; show what's already done.
    @ViewBuilder
    private var partialResult: some View {
        if model.operation.proseStyle != nil, !model.reformatted.isEmpty {
            ScrollView {
                Text(model.reformatted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var finishedResult: some View {
        switch model.operation {
        case .summary:
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary.abstract)
                        .textSelection(.enabled)
                    bulletList(summary.keyPoints)
                }
            }
        case .table:
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.topic)
                            .bold()
                            .textSelection(.enabled)
                        Text(row.detail)
                            .textSelection(.enabled)
                    }
                    Divider()
                        .gridCellColumns(2)
                }
            }
        case .reformat, .rewrite, .friendly, .professional, .concise, .list:
            Text(model.reformatted)
                .textSelection(.enabled)
        }
    }

    private func bulletList(_ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Label {
                    Text(point).textSelection(.enabled)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch model.operation {
        case .summary: "Summary"
        case .reformat: "Reformatted Transcript"
        case .rewrite: "Rewritten Transcript"
        case .friendly: "Friendly Rewrite"
        case .professional: "Professional Rewrite"
        case .concise: "Concise Rewrite"
        case .list: "Transcript List"
        case .table: "Transcript Table"
        }
    }

    private var defaultFilename: String {
        switch model.operation {
        case .summary:
            String(localized: "Luma Summary", locale: AppLanguage.currentLocale())
        case .reformat, .rewrite, .friendly, .professional, .concise, .list, .table:
            String(localized: "Luma Transcript", locale: AppLanguage.currentLocale())
        }
    }

    private var markdownType: UTType {
        UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    }

    private func export(as type: UTType) {
        exportType = type
        isExporting = true
    }

    private func copyResult() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.resultText, forType: .string)
        #else
        UIPasteboard.general.string = model.resultText
        #endif
    }
}

/// Minimal text file for `.fileExporter` (.txt / .md).
private struct TextExportDocument: FileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.plainText]
    nonisolated static let writableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
