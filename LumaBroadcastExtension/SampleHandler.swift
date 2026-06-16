import AVFAudio
import CoreMedia
import ReplayKit

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
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let canonicalFormat = BroadcastAudio.makeCanonicalFormat()

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
        }
        DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.started)
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
    ) {
        // Other apps' audio only; the screen frames and mic are not our concern.
        guard sampleBufferType == .audioApp else { return }
        guard let mono = makeCanonicalBuffer(from: sampleBuffer),
            let channel = mono.floatChannelData?[0]
        else { return }
        let byteCount = Int(mono.frameLength) * MemoryLayout<Float>.size
        guard byteCount > 0 else { return }

        lock.lock()
        ring?.write(UnsafeRawBufferPointer(start: channel, count: byteCount))
        lock.unlock()
        DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.audio)
    }

    override func broadcastFinished() {
        DarwinNotificationCenter.shared.post(BroadcastAudio.Notification.finished)
        lock.lock()
        ring?.close()
        ring = nil
        lock.unlock()
    }

    /// Converts a ReplayKit app-audio sample buffer to canonical mono Float32.
    private func makeCanonicalBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        var asbd = asbdPointer.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, let source = AVAudioFormat(streamDescription: &asbd) else { return nil }

        if converter == nil || !(sourceFormat?.isEqual(source) ?? false) {
            converter = AVAudioConverter(from: source, to: canonicalFormat)
            sourceFormat = source
        }
        guard let converter,
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: source, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frameCount),
                into: sourceBuffer.mutableAudioBufferList) == noErr
        else { return nil }

        let ratio = canonicalFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity)
        else { return nil }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
