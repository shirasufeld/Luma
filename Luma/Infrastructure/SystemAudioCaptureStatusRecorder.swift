import Foundation

/// Persists the outcome of the most recent system-audio capture start.
///
/// The "System Audio Recording" TCC cannot be queried, only triggered; the
/// capture provider records how each start ended and Diagnostics reads it
/// back, surviving relaunches via UserDefaults.
nonisolated enum SystemAudioCaptureStatusRecorder {
    static let defaultsKey = "systemAudio.lastCaptureOutcome"

    static func record(_ status: SystemAudioCaptureStatus, in defaults: UserDefaults = .standard) {
        defaults.set(status.rawValue, forKey: defaultsKey)
    }

    static func status(in defaults: UserDefaults = .standard) -> SystemAudioCaptureStatus {
        defaults.string(forKey: defaultsKey)
            .flatMap(SystemAudioCaptureStatus.init(rawValue:)) ?? .notAttempted
    }
}
