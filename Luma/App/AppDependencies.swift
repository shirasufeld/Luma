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
    /// Audio process tap on macOS and a ReplayKit broadcast-upload extension on
    /// iOS (see `BroadcastAudioProvider`).
    private nonisolated static func makeAudioProvider(_ kind: AudioInputKind) -> any AudioInputProviding {
        switch kind {
        case .microphone:
            return MicrophoneAudioProvider()
        case .systemAudio:
            #if os(macOS)
            return SystemAudioTapProvider()
            #else
            // iOS can't tap other apps' audio in-process; the broadcast-upload
            // extension forwards PCM through the App Group and this provider
            // drains it. The user starts the system broadcast from the UI.
            return BroadcastAudioProvider()
            #endif
        }
    }
}
