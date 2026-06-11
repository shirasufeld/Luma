import Foundation
import Translation

/// Translation built on the macOS 26+ programmatic `TranslationSession`
/// initializer (`init(installedSource:target:)`), which works for installed
/// language pairs without any SwiftUI involvement. Model downloads go
/// through `TranslationDownloadBridge` instead, because only
/// `.translationTask`-provided sessions may request downloads (verified in
/// docs/research.md §2).
actor AppleTranslationProvider: TranslationProviding {
    private let engine = TranslationEngine()
    private var availability: TranslationAvailability = .unsupported

    func setLanguagePair(
        source: Locale.Language,
        target: Locale.Language
    ) async -> TranslationAvailability {
        availability = await engine.configure(source: source, target: target)
        return availability
    }

    func translate(_ text: String) async throws -> String {
        guard availability == .installed else {
            throw TranslationPipelineError.languagePairNotReady
        }
        return try await engine.translate(text)
    }
}

/// Holds the non-Sendable `TranslationSession` and `LanguageAvailability`
/// instances entirely on the concurrent executor (`@concurrent` methods), so
/// they never cross an isolation boundary.
///
/// `@unchecked Sendable` discipline: the owning `AppleTranslationProvider`
/// actor serializes every call, so the mutable state below is never accessed
/// concurrently.
private nonisolated final class TranslationEngine: @unchecked Sendable {
    private var session: TranslationSession?
    private var configuredPair: (source: Locale.Language, target: Locale.Language)?

    @concurrent
    func configure(
        source: Locale.Language,
        target: Locale.Language
    ) async -> TranslationAvailability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            let pairUnchanged =
                configuredPair.map { $0.source == source && $0.target == target } ?? false
            if session == nil || !pairUnchanged {
                let session = Self.makeSession(source: source, target: target)
                // Warm the models so the first caption translates quickly.
                try? await session.prepareTranslation()
                self.session = session
                configuredPair = (source, target)
            }
            return .installed
        case .supported:
            session = nil
            configuredPair = nil
            return .supported
        case .unsupported:
            session = nil
            configuredPair = nil
            return .unsupported
        @unknown default:
            session = nil
            configuredPair = nil
            return .unsupported
        }
    }

    @concurrent
    func translate(_ text: String) async throws -> String {
        guard let session else {
            throw TranslationPipelineError.languagePairNotReady
        }
        return try await session.translate(text).targetText
    }

    private static func makeSession(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession {
        if #available(macOS 26.4, *) {
            TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            TranslationSession(installedSource: source, target: target)
        }
    }
}
