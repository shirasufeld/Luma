import AVFAudio
import Accelerate

/// Normalized input-level measurement for the live audio meter.
nonisolated enum AudioLevel {
    /// Readings at or below this RMS power are shown as silence.
    private static let floorDB: Float = -50

    /// RMS power of the buffer's first channel mapped to 0…1
    /// (`floorDB` → 0, full scale → 1), or nil for non-float PCM.
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDB) / -floorDB))
    }
}
