import Foundation

/// Read-only inspection of permissions and on-device model availability.
///
/// Implementations talk to AVFoundation, Speech, and Translation; everything
/// above the Services layer sees only this protocol.
nonisolated protocol CapabilityChecking: Sendable {
    /// Current microphone permission without prompting.
    func microphonePermission() -> PermissionState

    /// Prompts for microphone access if not determined yet.
    func requestMicrophonePermission() async -> PermissionState

    /// Transcription support and asset state for a locale.
    func transcriptionAvailability(for locale: Locale) async -> TranscriptionAvailability

    /// Locales the transcription engine supports on this device.
    func supportedTranscriptionLocales() async -> [Locale]

    /// Translation support for a language pair.
    func translationAvailability(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> TranslationAvailability

    /// Languages the translation engine supports on this device.
    func supportedTranslationLanguages() async -> [Locale.Language]
}
