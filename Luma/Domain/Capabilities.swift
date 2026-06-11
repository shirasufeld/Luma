import Foundation

/// Authorization state for a system permission (microphone, system audio capture).
nonisolated enum PermissionState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
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
    /// System audio capture permission has no query API; the system prompts on
    /// first use of a tap-backed aggregate device, so this stays `notDetermined`
    /// until a capture attempt succeeds or fails.
    var systemAudioCapture: PermissionState = .notDetermined
}
