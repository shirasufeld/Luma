import SwiftUI
import Translation

/// The one sanctioned piece of SwiftUI in the Infrastructure layer.
///
/// Only sessions provided by the `.translationTask` modifier may ask the
/// system to download language models, so this invisible view hosts that
/// modifier, runs `prepareTranslation()` (which presents the system download
/// prompt when needed), and reports the outcome. Mount it only while a
/// download is wanted.
struct TranslationDownloadBridge: View {
    let source: Locale.Language
    let target: Locale.Language
    let onFinished: @MainActor (_ success: Bool) -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(configuration) { session in
                let success = await Self.prepare(SessionBox(session: session))
                onFinished(success)
            }
            .onAppear {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
    }

    /// `TranslationSession` is not Sendable; the box hands it to the
    /// concurrent executor where `prepareTranslation()` runs without leaving
    /// that isolation domain. The session is only used for this one call.
    private nonisolated struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    @concurrent
    private static func prepare(_ box: SessionBox) async -> Bool {
        do {
            try await box.session.prepareTranslation()
            return true
        } catch {
            return false
        }
    }
}
