#if os(iOS)
import AVFAudio
import Foundation

/// iOS system-audio capture via a ReplayKit broadcast-upload extension.
///
/// iOS has no in-process API for other apps' audio (ScreenCaptureKit only
/// captures the current app). Instead the user starts a system broadcast; the
/// extension forwards PCM through the App Group ring buffer and this provider
/// drains it into the existing transcription pipeline. The provider is created
/// up front and idles until the broadcast actually starts producing audio.
///
/// See `MicrophoneAudioProvider` for the cross-platform sibling and
/// `SystemAudioTapProvider` for the macOS process-tap path.
actor BroadcastAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .systemAudio

    private let format = BroadcastAudio.makeCanonicalFormat()
    private var ring: SharedAudioRing?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var audioToken: DarwinNotificationCenter.Token?
    private var finishToken: DarwinNotificationCenter.Token?
    private var isPaused = false
    private var scratch = Data()

    func start() async throws -> AsyncStream<AudioChunk> {
        teardown()
        guard let url = BroadcastAudio.ringURL() else {
            throw BroadcastAudioError.appGroupUnavailable
        }
        // The consumer owns the ring lifecycle: create (resetting indices) on
        // start, delete on stop. The extension opens the same file.
        ring = try SharedAudioRing(
            url: url, capacityBytes: BroadcastAudio.ringCapacityBytes, create: true)

        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation

        audioToken = DarwinNotificationCenter.shared.observe(BroadcastAudio.Notification.audio) {
            [weak self] in
            Task { await self?.drain() }
        }
        finishToken = DarwinNotificationCenter.shared.observe(BroadcastAudio.Notification.finished) {
            [weak self] in
            Task { await self?.finishStream() }
        }
        return stream
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func stop() async {
        teardown()
    }

    /// Drains all pending PCM and yields it as one chunk per notification.
    private func drain() {
        guard !isPaused, let ring, let continuation else { return }
        let byteCount = ring.read(into: &scratch)
        let frameCount = byteCount / MemoryLayout<Float>.size
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        scratch.withUnsafeBytes { raw in
            if let destination = buffer.floatChannelData?[0], let source = raw.baseAddress {
                memcpy(destination, source, frameCount * MemoryLayout<Float>.size)
            }
        }
        continuation.yield(AudioChunk(buffer: buffer))
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }

    private func teardown() {
        if let audioToken { DarwinNotificationCenter.shared.cancel(audioToken) }
        if let finishToken { DarwinNotificationCenter.shared.cancel(finishToken) }
        audioToken = nil
        finishToken = nil
        continuation?.finish()
        continuation = nil
        ring?.close()
        ring = nil
        if let url = BroadcastAudio.ringURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum BroadcastAudioError: Error {
    case appGroupUnavailable
}
#endif
