import Foundation

/// Composition root. Creates production service implementations and hands
/// them to the UI as protocols so views and view models never touch system
/// frameworks directly.
@MainActor
final class AppDependencies {
    let capabilities: any CapabilityChecking
    let store: SessionStore
    let session: SessionController
    let overlay: SubtitleOverlayController
    let exporter: any TranscriptExporting

    init(
        capabilities: any CapabilityChecking = CapabilityService(),
        transcription: (any TranscriptionProviding)? = nil,
        translation: (any TranslationProviding)? = nil,
        audioProviderFactory: (@Sendable (AudioInputKind) -> any AudioInputProviding)? = nil
    ) {
        self.capabilities = capabilities
        let store = SessionStore()
        self.store = store
        self.overlay = SubtitleOverlayController(store: store)
        #if os(macOS)
        self.exporter = TranscriptExportService()
        #else
        self.exporter = DocumentExportService()
        #endif
        self.session = SessionController(
            store: store,
            capabilities: capabilities,
            transcription: transcription ?? SpeechAnalyzerTranscriber(),
            translation: translation ?? AppleTranslationProvider(),
            audioProviderFactory: audioProviderFactory ?? Self.makeAudioProvider
        )
    }

    /// Builds the platform-appropriate capture provider for a given source.
    /// Microphone capture is cross-platform; system-audio capture uses a Core
    /// Audio process tap on macOS and ScreenCaptureKit (iOS 27+) on iOS.
    private nonisolated static func makeAudioProvider(_ kind: AudioInputKind) -> any AudioInputProviding {
        switch kind {
        case .microphone:
            return MicrophoneAudioProvider()
        case .systemAudio:
            #if os(macOS)
            return SystemAudioTapProvider()
            #else
            // iOS has no public API to capture other apps' system audio
            // (ScreenCaptureKit only captures the current app), so the UI does
            // not offer this source; fall back to the microphone defensively.
            return MicrophoneAudioProvider()
            #endif
        }
    }
}
