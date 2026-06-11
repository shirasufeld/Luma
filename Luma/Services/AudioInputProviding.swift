import AVFAudio

/// Identifies which kind of audio source a provider captures.
nonisolated enum AudioInputKind: String, Sendable, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }
}

/// A source of live PCM audio (microphone, system audio tap, mock playback).
///
/// Lifecycle: `start()` begins capture and returns a stream that stays open
/// across `pause()`/`resume()` and finishes after `stop()` (or on failure).
nonisolated protocol AudioInputProviding: Sendable {
    var kind: AudioInputKind { get }

    /// Begins capture. The returned stream delivers chunks in capture order.
    func start() async throws -> AsyncStream<AudioChunk>

    /// Temporarily halts capture without finishing the stream.
    func pause() async

    /// Resumes capture after `pause()`.
    func resume() async throws

    /// Ends capture and finishes the stream.
    func stop() async
}
