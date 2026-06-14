#if os(iOS)
import AVFAudio

/// Process-wide iOS audio session coordination.
///
/// Two independent features need the shared `AVAudioSession`: microphone
/// capture (`.playAndRecord`) and the caption Picture in Picture window (which
/// needs an *active* session to start — `.playback` is enough when not
/// recording). Each declares its need and the coordinator picks the strongest
/// category and toggles activation once, so neither feature tears down a
/// session the other still needs — and PiP can start even before a transcription
/// session has run.
actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private var needsRecording = false
    private var needsPictureInPicture = false

    func setRecording(_ active: Bool) {
        needsRecording = active
        apply()
    }

    func setPictureInPicture(_ active: Bool) {
        needsPictureInPicture = active
        apply()
    }

    private func apply() {
        let session = AVAudioSession.sharedInstance()
        do {
            if needsRecording {
                // `.measurement` gives the cleanest, unprocessed mic input for
                // speech recognition; `.mixWithOthers` keeps other apps playing.
                try session.setCategory(
                    .playAndRecord, mode: .measurement,
                    options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
            } else if needsPictureInPicture {
                // No microphone in use — a playback session is enough to keep
                // PiP alive and clears the recording indicator.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } else {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            // Best effort: a failed activation surfaces as PiP failing to start
            // or the engine failing to start, both already handled by callers.
        }
    }
}
#endif
