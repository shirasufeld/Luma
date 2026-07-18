import AVFAudio
import CoreMedia
import ReplayKit
import os

/// ReplayKit broadcast-upload extension entry point.
///
/// The extension runs in a separate, memory-constrained process (~50 MB), so it
/// does **no** transcription: it only extracts the *other apps'* audio
/// (`.audioApp`), converts it to the canonical mono Float32 PCM, and forwards it
/// to the main app through the App Group ring buffer. The main app — kept alive
/// by its caption Picture in Picture — does the transcription/translation.
///
/// ReplayKit delivers the lifecycle and sample callbacks serially, but not
/// necessarily on one thread, so shared state is guarded by `lock`.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var ring: SharedAudioRing?
    private var heartbeat: DispatchSourceTimer?
    private let converter = CanonicalPCMConverter(
        canonicalFormat: BroadcastAudio.makeCanonicalFormat())
    private let logger = BroadcastAudio.makeLogger(category: "BroadcastExtension")

    // Counters (under `lock`) reported on the heartbeat cadence — the primary
    // field diagnostic for "broadcast alive but no captions".
    private var received = 0
    private var forwarded = 0
    private var dropped = 0
    private var dropCounts: [String: Int] = [:]

    override init() {
        super.init()
        converter.onSourceFormatChange = { [logger] asbd in
            logger.info(
                """
                source format: rate=\(asbd.mSampleRate, privacy: .public) \
                ch=\(asbd.mChannelsPerFrame, privacy: .public) \
                bits=\(asbd.mBitsPerChannel, privacy: .public) \
                flags=\(asbd.mFormatFlags, privacy: .public) \
                id=\(asbd.mFormatID, privacy: .public)
                """)
        }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        if let url = BroadcastAudio.ringURL() {
            // The main app normally creates the ring first; fall back to
            // creating it if the broadcast was started before the app's session.
            let opened =
                (try? SharedAudioRing(
                    url: url, capacityBytes: BroadcastAudio.ringCapacityBytes, create: false))
                ?? (try? SharedAudioRing(
                    url: url, capacityBytes: BroadcastAudio.ringCapacityBytes, create: true))
            lock.lock()
            ring = opened
            lock.unlock()
            if opened == nil {
                logger.error("broadcast started but the ring could not be opened")
            } else {
                logger.info("broadcast started, ring open")
            }
        } else {
            logger.error("broadcast started but the App Group container is unavailable")
        }
        // Liveness heartbeat: `.finished` never fires if this process dies
        // uncleanly, so the app-side observers watch for this going quiet.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now(), repeating: BroadcastAudio.heartbeatInterval, leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.heartbeat)
            guard let self else { return }
            self.lock.lock()
            let line =
                "heartbeat received=\(self.received) forwarded=\(self.forwarded)"
                + " dropped=\(self.dropped)"
            self.lock.unlock()
            self.logger.info("\(line, privacy: .public)")
        }
        timer.resume()
        lock.lock()
        heartbeat = timer
        lock.unlock()
        DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.started)
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
    ) {
        // Other apps' audio only; the screen frames and mic are not our concern.
        guard sampleBufferType == .audioApp else { return }
        lock.lock()
        received += 1
        var postAudio = false
        var dropLine: String?
        switch converter.convert(sampleBuffer) {
        case .success(let mono):
            // Zero frames is not a drop: the converter buffered this input
            // and will emit it with a later call.
            let byteCount = Int(mono.frameLength) * MemoryLayout<Float>.size
            if byteCount > 0, let channel = mono.floatChannelData?[0] {
                ring?.write(UnsafeRawBufferPointer(start: channel, count: byteCount))
                forwarded += 1
                postAudio = true
            }
        case .failure(let reason):
            dropped += 1
            dropLine = throttledDropLine(reason.description)
        }
        lock.unlock()
        if let dropLine {
            logger.error("\(dropLine, privacy: .public)")
        }
        if postAudio {
            DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.audio)
        }
    }

    override func broadcastFinished() {
        DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.finished)
        lock.lock()
        heartbeat?.cancel()
        heartbeat = nil
        ring?.close()
        ring = nil
        let line =
            "broadcast finished received=\(received) forwarded=\(forwarded)"
            + " dropped=\(dropped)"
        lock.unlock()
        logger.info("\(line, privacy: .public)")
    }

    /// Caller must hold `lock`. Returns a log line for the first occurrence of
    /// each drop reason and every 100th after that, keeping the log quiet while
    /// a persistent failure stays visible.
    private func throttledDropLine(_ reason: String) -> String? {
        let count = (dropCounts[reason] ?? 0) + 1
        dropCounts[reason] = count
        guard count == 1 || count.isMultiple(of: 100) else { return nil }
        return "dropped sample (\(reason)) count=\(count)"
    }
}
