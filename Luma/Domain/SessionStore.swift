import CoreMedia
import Foundation
import Observation

private nonisolated let translationModeDefaultsKey = "translation.mode"

/// Single source of truth for everything the UI shows. Mutated only on the
/// main actor; the session controller hops here to publish updates.
@MainActor
@Observable
final class SessionStore {
    // Caption content.
    private(set) var buffer = SubtitleBuffer()

    // Session status.
    private(set) var sessionState: SessionState = .idle
    private(set) var modelState: TranscriptionModelState?
    private(set) var audioInput: AudioInputState = .idle
    private(set) var errorMessage: String?
    /// Estimated end-to-end caption latency in seconds (audio end → display).
    private(set) var latency: TimeInterval?
    /// Locale actually used by the transcriber after resolution.
    private(set) var resolvedTranscriptionLocale: Locale?
    /// Whether the active language pair can translate (and if not, why).
    private(set) var translationAvailability: TranslationAvailability?
    /// Live translation of the volatile hypothesis (fast mode only).
    private(set) var volatileTranslation: String?

    // User configuration.
    var languagePair: LanguagePair = .default
    var inputKind: AudioInputKind = .microphone
    var translationMode: TranslationMode =
        UserDefaults.standard.string(forKey: translationModeDefaultsKey)
        .flatMap(TranslationMode.init(rawValue:)) ?? .balanced
    {
        didSet {
            UserDefaults.standard.set(
                translationMode.rawValue, forKey: translationModeDefaultsKey)
        }
    }

    var entries: [SubtitleEntry] { buffer.entries }
    var volatileText: AttributedString? { buffer.volatileText }

    // MARK: - Updates from the session controller

    func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        switch state {
        case .idle, .stopping:
            audioInput = .idle
            latency = nil
        case .running:
            audioInput = .capturing(inputKind)
            errorMessage = nil
        case .paused:
            audioInput = .paused(inputKind)
        case .preparing:
            break
        }
    }

    func modelStateChanged(_ state: TranscriptionModelState) {
        modelState = state
    }

    func transcriptionDidResolve(locale: Locale) {
        resolvedTranscriptionLocale = locale
    }

    func translationAvailabilityChanged(_ availability: TranslationAvailability) {
        translationAvailability = availability
    }

    func applyVolatile(text: AttributedString, range: CMTimeRange, latency: TimeInterval?) {
        buffer.applyVolatile(text: text, range: range)
        if let latency { self.latency = latency }
    }

    /// Returns true when the segment was new and appended.
    @discardableResult
    func applyFinalized(_ segment: TranscriptSegment, latency: TimeInterval?) -> Bool {
        let appended = buffer.applyFinalized(segment)
        // The finalized line supersedes the volatile hypothesis and its
        // live translation.
        volatileTranslation = nil
        if let latency { self.latency = latency }
        return appended
    }

    func applyVolatileTranslation(_ text: String?) {
        // Only meaningful while a volatile line is on screen.
        guard text == nil || buffer.volatileText != nil else { return }
        volatileTranslation = text
    }

    func applyTranslation(segmentID: UUID, state: TranslationState) {
        buffer.applyTranslation(segmentID: segmentID, state: state)
    }

    func sessionFailed(_ message: String) {
        errorMessage = message
        sessionState = .idle
        audioInput = .failed(message)
    }

    func clearTranscript() {
        buffer.clear()
        volatileTranslation = nil
        latency = nil
    }
}
