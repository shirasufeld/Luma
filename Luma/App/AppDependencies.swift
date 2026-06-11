import Foundation

/// Composition root. Creates production service implementations and hands
/// them to the UI as protocols so views and view models never touch system
/// frameworks directly.
@MainActor
final class AppDependencies {
    let capabilities: any CapabilityChecking
    let store: SessionStore
    let session: SessionController

    init(
        capabilities: any CapabilityChecking = CapabilityService(),
        transcription: (any TranscriptionProviding)? = nil,
        translation: (any TranslationProviding)? = nil,
        audioProviderFactory: (@Sendable (AudioInputKind) -> any AudioInputProviding)? = nil
    ) {
        self.capabilities = capabilities
        let store = SessionStore()
        self.store = store
        self.session = SessionController(
            store: store,
            capabilities: capabilities,
            transcription: transcription ?? SpeechAnalyzerTranscriber(),
            translation: translation ?? AppleTranslationProvider(),
            audioProviderFactory: audioProviderFactory ?? { kind in
                switch kind {
                case .microphone:
                    MicrophoneAudioProvider()
                case .systemAudio:
                    SystemAudioTapProvider()
                }
            }
        )
    }
}
