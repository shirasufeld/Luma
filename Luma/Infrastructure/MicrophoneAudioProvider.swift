import AVFAudio

/// Captures microphone audio with `AVAudioEngine` and exposes it as an
/// `AsyncStream<AudioChunk>` in the input node's native format. Format
/// conversion for the transcriber happens downstream.
actor MicrophoneAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .microphone

    /// ~43 ms at 48 kHz; a balance between latency and per-chunk overhead.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isTapInstalled = false

    func start() throws -> AsyncStream<AudioChunk> {
        stopCaptureIfNeeded()

        #if os(iOS)
        // iOS requires an active audio session before the engine can tap the
        // microphone. `.measurement` gives the cleanest, unprocessed input for
        // speech recognition. macOS needs none of this.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation

        // The tap block runs on a realtime audio thread; it only wraps the
        // buffer and hands it to the stream.
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            buffer, time in
            continuation.yield(AudioChunk(buffer: buffer, time: time))
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopCaptureIfNeeded()
            continuation.finish()
            self.continuation = nil
            throw error
        }
        return stream
    }

    func pause() {
        engine.pause()
    }

    func resume() throws {
        guard isTapInstalled else { return }
        try engine.start()
    }

    func stop() {
        stopCaptureIfNeeded()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func stopCaptureIfNeeded() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
