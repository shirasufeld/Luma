#if os(iOS)
import Foundation

/// Tracks whether a system broadcast (our ReplayKit upload extension) is
/// currently running, so the UI can show "waiting for broadcast" vs
/// "broadcasting" instead of leaving the user to guess whether audio flows.
///
/// Driven by the extension's Darwin notifications. Darwin notifications carry
/// no state and can't be queried, so a broadcast already running before app
/// launch reads as inactive until its next audio buffer arrives — which is why
/// `.audio` also flips the flag on.
@MainActor
@Observable
final class BroadcastStateMonitor {
    private(set) var isBroadcastActive = false

    @ObservationIgnored private var tokens: [DarwinNotificationCenter.Token] = []

    init() {
        observe(BroadcastAudio.Notification.started, as: true)
        observe(BroadcastAudio.Notification.audio, as: true)
        observe(BroadcastAudio.Notification.finished, as: false)
    }

    deinit {
        for token in tokens { DarwinNotificationCenter.shared.cancel(token) }
    }

    private func observe(_ name: String, as active: Bool) {
        tokens.append(
            DarwinNotificationCenter.shared.observe(name) { [weak self] in
                Task { @MainActor in self?.setActive(active) }
            })
    }

    private func setActive(_ active: Bool) {
        // `.audio` fires tens of times per second while broadcasting; only
        // touch the observable property when the state actually changes.
        if isBroadcastActive != active {
            isBroadcastActive = active
        }
    }
}
#endif
