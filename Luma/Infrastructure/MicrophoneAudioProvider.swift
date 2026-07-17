import AVFAudio

/// Captures microphone audio with `AVAudioEngine` and exposes it as an
/// `AsyncStream<AudioChunk>` in the input node's native format. Format
/// conversion for the transcriber happens downstream (the converters rebuild
/// when a chunk's format changes, so a mid-session format switch is safe).
actor MicrophoneAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .microphone

    /// ~43 ms at 48 kHz; a balance between latency and per-chunk overhead.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isTapInstalled = false
    private var isPaused = false
    private var observerTokens: [NSObjectProtocol] = []

    func start() async throws -> AsyncStream<AudioChunk> {
        stopCaptureIfNeeded()

        #if os(iOS)
        // iOS needs an active audio session before the engine can tap the
        // microphone. The coordinator owns the session so recording and the
        // caption PiP window don't fight over it (macOS needs none of this).
        await AudioSessionCoordinator.shared.setRecording(true)
        #endif

        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        isPaused = false

        installTap(with: continuation)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopCaptureIfNeeded()
            continuation.finish()
            self.continuation = nil
            #if os(iOS)
            await AudioSessionCoordinator.shared.setRecording(false)
            #endif
            throw error
        }
        installObservers()
        return stream
    }

    func pause() {
        isPaused = true
        engine.pause()
    }

    func resume() throws {
        guard isTapInstalled else { return }
        isPaused = false
        try engine.start()
    }

    func stop() async {
        removeObservers()
        stopCaptureIfNeeded()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        await AudioSessionCoordinator.shared.setRecording(false)
        #endif
    }

    // MARK: - Route changes and interruptions

    /// The engine stops itself when the audio hardware changes shape (e.g.
    /// Bluetooth headphones connect/disconnect) or, on iOS, when another
    /// audio session interrupts (phone call, Siri). Without recovery the
    /// session would sit in "Live" with frozen captions; reinstall the tap
    /// with the input's current format and restart, or end the stream
    /// cleanly so the session stops visibly instead of hanging.
    private func installObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { await self?.handleConfigurationChange() }
            })
        #if os(iOS)
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                let ended =
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
                Task { await self?.handleInterruption(ended: ended) }
            })
        #endif
    }

    private func removeObservers() {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
    }

    private func handleConfigurationChange() {
        guard let continuation, isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap(with: continuation)
        restartEngineOrFinish()
    }

    #if os(iOS)
    private func handleInterruption(ended: Bool) {
        guard continuation != nil, isTapInstalled, ended else { return }
        // The system stopped the engine when the interruption began; bring
        // capture back now that it's over (unless the user paused meanwhile).
        restartEngineOrFinish()
    }
    #endif

    private func restartEngineOrFinish() {
        guard !isPaused else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Can't recover capture: end the stream so the session stops
            // cleanly instead of pretending to listen.
            continuation?.finish()
            continuation = nil
        }
    }

    private func installTap(with continuation: AsyncStream<AudioChunk>.Continuation) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The tap block runs on a realtime audio thread; it only wraps the
        // buffer and hands it to the stream.
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
            buffer, time in
            continuation.yield(AudioChunk(buffer: buffer, time: time))
        }
        isTapInstalled = true
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
