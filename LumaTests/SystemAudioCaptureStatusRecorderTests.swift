import Foundation
import Testing

@testable import Luma

struct SystemAudioCaptureStatusRecorderTests {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.\(name)")!
        defaults.removePersistentDomain(forName: "test.\(name)")
        return defaults
    }

    @Test func defaultsToNotAttempted() {
        let defaults = makeDefaults()
        #expect(SystemAudioCaptureStatusRecorder.status(in: defaults) == .notAttempted)
    }

    @Test func roundTripsEachStatus() {
        let defaults = makeDefaults()
        for status in [SystemAudioCaptureStatus.working, .failed, .notAttempted] {
            SystemAudioCaptureStatusRecorder.record(status, in: defaults)
            #expect(SystemAudioCaptureStatusRecorder.status(in: defaults) == status)
        }
    }

    @Test func garbageValueFallsBackToNotAttempted() {
        let defaults = makeDefaults()
        defaults.set("definitely-not-a-status", forKey: SystemAudioCaptureStatusRecorder.defaultsKey)
        #expect(SystemAudioCaptureStatusRecorder.status(in: defaults) == .notAttempted)
    }
}
