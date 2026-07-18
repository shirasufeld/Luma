import CoreMedia
import Foundation
import Observation

private nonisolated let translationModeDefaultsKey = "translation.mode"
private nonisolated let inputKindDefaultsKey = "audio.inputKind"
private nonisolated let transcriptionLocaleDefaultsKey = "language.transcriptionLocale"
private nonisolated let translationTargetDefaultsKey = "language.translationTarget"

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
    /// Normalized input level (0…1) of the captured audio; nil when nothing
    /// is being captured. The visible proof that audio is arriving at all.
    private(set) var audioLevel: Float?

    // User configuration — persisted so the app relaunches the way it was
    // last used (these are now primary main-screen controls).
    var languagePair: LanguagePair = .default {
        didSet {
            guard didRestore else { return }
            defaults.set(
                languagePair.transcriptionLocale.identifier,
                forKey: transcriptionLocaleDefaultsKey)
            defaults.set(
                languagePair.translationTarget?.maximalIdentifier
                    ?? LanguagePair.noneTargetValue,
                forKey: translationTargetDefaultsKey)
        }
    }
    var inputKind: AudioInputKind = .microphone {
        didSet {
            guard didRestore else { return }
            defaults.set(inputKind.rawValue, forKey: inputKindDefaultsKey)
        }
    }
    var translationMode: TranslationMode = .balanced {
        didSet {
            guard didRestore else { return }
            defaults.set(translationMode.rawValue, forKey: translationModeDefaultsKey)
        }
    }

    private let defaults: UserDefaults
    /// Under `@Observable`, assignments in the init body DO run `didSet`
    /// (they go through the macro-generated setter) — this flag keeps
    /// restoration from writing anything back until it has finished.
    private var didRestore = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let kind = defaults.string(forKey: inputKindDefaultsKey)
            .flatMap(AudioInputKind.init(rawValue:))
        {
            inputKind = kind
        }
        if let mode = defaults.string(forKey: translationModeDefaultsKey)
            .flatMap(TranslationMode.init(rawValue:))
        {
            translationMode = mode
        }
        // The two language keys restore independently so one missing key
        // never discards the other's persisted value.
        if let locale = defaults.string(forKey: transcriptionLocaleDefaultsKey) {
            languagePair.transcriptionLocale = Locale(identifier: locale)
        }
        if let target = defaults.string(forKey: translationTargetDefaultsKey) {
            languagePair.translationTarget =
                target == LanguagePair.noneTargetValue
                ? nil : Locale.Language(identifier: target)
        }
        didRestore = true
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
            audioLevel = nil
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

    func audioLevelChanged(_ level: Float?) {
        audioLevel = level
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
