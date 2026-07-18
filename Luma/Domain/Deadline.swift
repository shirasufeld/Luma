import Foundation
import Synchronization

/// Bounded wait for operations that may never return.
///
/// Motivated by `SpeechAnalyzer`: on a zero-audio session (iOS 26 beta) both
/// `finalizeAndFinishThroughEndOfInput()` and `cancelAndFinishNow()` were
/// observed to hang forever, so no teardown call on it may be awaited
/// unboundedly — and no "cancel to unblock" scheme helps when the cancel call
/// itself hangs.
nonisolated enum Deadline {
    /// Runs `operation`, waiting at most `timeout` for it to complete.
    ///
    /// Returns true if it finished in time. Returns false if it was
    /// **abandoned**: the operation keeps running detached and whatever it
    /// captures stays alive — the accepted cost for a bounded caller.
    ///
    /// Implemented as two independent racing tasks resuming a continuation
    /// once. Deliberately NOT a task group: a group awaits all of its
    /// children before returning, so one hung child would hang the group.
    @discardableResult
    static func run(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let winner = OnceFlag()
        return await withCheckedContinuation { continuation in
            Task {
                await operation()
                if winner.tryClaim() {
                    continuation.resume(returning: true)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if winner.tryClaim() {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// First-caller-wins latch shared by the two racing tasks.
    private final class OnceFlag: Sendable {
        private let claimed = Atomic<Bool>(false)

        func tryClaim() -> Bool {
            !claimed.exchange(true, ordering: .sequentiallyConsistent)
        }
    }
}
