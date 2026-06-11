import AVFAudio

/// A slice of captured PCM audio with its source timestamp.
///
/// `AVAudioPCMBuffer` is not `Sendable`; this wrapper is `@unchecked Sendable`
/// under a strict ownership rule: a chunk is created by exactly one producer,
/// yielded into an `AsyncStream`, and consumed by exactly one downstream
/// consumer. Nobody mutates the buffer after creation.
nonisolated struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Capture-device timestamp for the first frame, when the source provides one.
    let time: AVAudioTime?

    init(buffer: AVAudioPCMBuffer, time: AVAudioTime? = nil) {
        self.buffer = buffer
        self.time = time
    }
}
