import Foundation

/// Authorization state for a system permission (microphone).
nonisolated enum PermissionState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

/// Outcome-based status for system-audio capture.
///
/// macOS has no public API to query the "System Audio Recording" TCC state
/// (the prompt fires on first tap start), and the iOS broadcast path has no
/// permission concept at all — so the app records how the most recent capture
/// attempt ended and Diagnostics reports that, in non-permission wording.
nonisolated enum SystemAudioCaptureStatus: String, Sendable, Equatable {
    case notAttempted
    case working
    case failed
}

/// Whether on-device transcription is possible for a locale, and whether its
/// model assets are already installed.
nonisolated enum TranscriptionAvailability: Sendable, Equatable {
    /// The device or OS cannot run the transcription models at all.
    case unavailableOnDevice
    /// The locale is not supported by the transcription models.
    case unsupportedLocale
    /// Supported, but model assets for the locale are not installed yet.
    /// The associated locale is the supported equivalent reported by the system.
    case supported(Locale)
    /// Supported and model assets are installed; ready to transcribe.
    case installed(Locale)
}

/// Whether on-device translation is possible for a language pair.
nonisolated enum TranslationAvailability: Sendable, Equatable {
    case installed
    /// Supported but the language models need to be downloaded first.
    case supported
    case unsupported
}

/// A point-in-time snapshot of everything the session needs to run.
nonisolated struct CapabilitySnapshot: Sendable, Equatable {
    var microphone: PermissionState = .notDetermined
    var transcription: TranscriptionAvailability = .unavailableOnDevice
    var translation: TranslationAvailability = .unsupported
    /// Last-known outcome of a system-audio capture start (macOS tap path).
    var systemAudioCapture: SystemAudioCaptureStatus = .notAttempted
}
