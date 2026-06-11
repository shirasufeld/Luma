import Foundation

/// Live speech-to-text. Implementations own the recognition engine; callers
/// interact only with domain types.
///
/// Lifecycle: `prepare(locale:onModelState:)` once per locale change, then
/// `start(consuming:)` per session. `finish()` finalizes pending audio and
/// ends the event stream gracefully; `cancel()` tears down immediately.
nonisolated protocol TranscriptionProviding: Sendable {
    /// Resolves the locale, ensures model assets are present (downloading if
    /// needed), and reports asset state transitions. Returns the resolved
    /// locale actually used by the engine.
    func prepare(
        locale: Locale,
        onModelState: @escaping @Sendable (TranscriptionModelState) -> Void
    ) async throws -> Locale

    /// Starts a transcription session over the given audio. Events arrive in
    /// audio order; the stream finishes after `finish()` drains or throws on
    /// engine failure.
    func start(
        consuming audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error>

    /// Finalizes any pending audio, then ends the event stream.
    func finish() async throws

    /// Stops immediately, discarding pending results.
    func cancel() async
}
