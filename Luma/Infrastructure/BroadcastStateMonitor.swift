#if os(iOS)
import Foundation

/// Tracks whether a system broadcast (our ReplayKit upload extension) is
/// currently running, so the UI can show "waiting for broadcast" vs
/// "broadcasting" instead of leaving the user to guess whether audio flows.
///
/// Driven by the extension's Darwin notifications. Darwin notifications carry
/// no state and can't be queried, so a broadcast already running before app
/// launch reads as inactive until its next audio buffer or heartbeat arrives —
/// which is why `.audio` and `.heartbeat` also flip the flag on. The heartbeat
/// doubles as liveness: if the extension dies without posting `.finished`
/// (jetsam kill, crash), the silence flips the flag back off after the
/// timeout, so the "Broadcasting" badge never lies indefinitely.
@MainActor
@Observable
final class BroadcastStateMonitor {
    private(set) var isBroadcastActive = false

    @ObservationIgnored private var tokens: [DarwinNotificationCenter.Token] = []
    @ObservationIgnored private var lastAlive = ContinuousClock.now
    @ObservationIgnored private var livenessTask: Task<Void, Never>?

    init() {
        observe(BroadcastAudio.Notification.started, as: true)
        observe(BroadcastAudio.Notification.audio, as: true)
        observe(BroadcastAudio.Notification.heartbeat, as: true)
        observe(BroadcastAudio.Notification.finished, as: false)
    }

    deinit {
        for token in tokens { DarwinNotificationCenter.shared.cancel(token) }
        livenessTask?.cancel()
    }

    private func observe(_ name: String, as active: Bool) {
        tokens.append(
            DarwinNotificationCenter.shared.observe(name) { [weak self] in
                Task { @MainActor in self?.setActive(active) }
            })
    }

    private func setActive(_ active: Bool) {
        if active { lastAlive = .now }
        // `.audio` fires tens of times per second while broadcasting; only
        // touch the observable property when the state actually changes.
        guard isBroadcastActive != active else { return }
        isBroadcastActive = active
        if active {
            startLivenessTask()
        } else {
            livenessTask?.cancel()
            livenessTask = nil
        }
    }

    /// While the broadcast reads as active, watch for its signals going quiet.
    private func startLivenessTask() {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BroadcastAudio.heartbeatInterval))
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastAlive
                    > .seconds(BroadcastAudio.livenessTimeout)
                {
                    self.setActive(false)
                    return
                }
            }
        }
    }
}
#endif
