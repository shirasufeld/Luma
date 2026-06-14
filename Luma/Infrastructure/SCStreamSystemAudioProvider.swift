#if os(iOS)
import Foundation

/// iOS system-audio capture via ScreenCaptureKit (`SCStream` with
/// `SCStreamConfiguration.capturesAudio`), which is available on iOS 27+.
///
/// Unlike macOS — where a Core Audio process tap captures other apps' output
/// silently after a one-time TCC prompt — iOS requires the user to grant
/// capture through `SCContentSharingPicker` each session, and the capture
/// scope is constrained by the iOS sandbox.
///
/// This is the M1 placeholder; real capture is implemented in M4. It is kept
/// behind `AudioInputProviding` so the rest of the app is unaffected by the
/// pending capture-scope work.
@available(iOS 27.0, *)
actor SCStreamSystemAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .systemAudio

    enum CaptureError: Error {
        /// System-audio capture is not yet implemented on iOS.
        case notImplemented
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        throw CaptureError.notImplemented
    }

    func pause() async {}

    func resume() async throws {}

    func stop() async {}
}
#endif
