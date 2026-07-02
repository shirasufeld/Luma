import Foundation

/// Thin wrapper over the Darwin notify center for cross-process signalling
/// between the broadcast-upload extension and the main app. Darwin
/// notifications carry no payload — they are pure wake-ups — so the audio
/// itself travels through `SharedAudioRing`; these just say "something changed".
///
/// `nonisolated` so the extension's background callbacks and the provider's
/// actor can post/observe without hopping to the app target's default main actor.
nonisolated final class DarwinNotificationCenter: @unchecked Sendable {
    static let shared = DarwinNotificationCenter()

    /// Cancellation handle for a registered observer.
    struct Token: Sendable {
        let name: String
        let id: UUID
    }

    private let lock = NSLock()
    private var handlers: [String: [UUID: @Sendable () -> Void]] = [:]
    private var registeredNames: Set<String> = []

    /// Posts a Darwin notification to every observing process.
    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Registers `handler` for `name`. Multiple handlers per name are allowed;
    /// the underlying Darwin observer is added exactly once per name and removed
    /// when the last handler for that name is cancelled (so a start→stop→start
    /// cycle never leaves a stale observer that double-fires).
    ///
    /// The CF add/remove calls happen inside `lock` so they stay ordered with
    /// the bookkeeping they mirror — otherwise a concurrent observe/cancel pair
    /// could land its add and remove in the opposite order, leaving live
    /// handlers with no underlying observer. Both CF calls are thread-safe and
    /// deliver callbacks asynchronously, so no re-entrancy under the lock.
    @discardableResult
    func observe(_ name: String, handler: @escaping @Sendable () -> Void) -> Token {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        handlers[name, default: [:]][id] = handler
        if !registeredNames.contains(name) {
            registeredNames.insert(name)
            // C callback can't capture context; it references the singleton and
            // fans out by name (which Darwin passes back to us).
            let callback: CFNotificationCallback = { _, _, name, _, _ in
                guard let raw = name?.rawValue as String? else { return }
                DarwinNotificationCenter.shared.fire(raw)
            }
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(DarwinNotificationCenter.shared).toOpaque(),
                callback, name as CFString, nil, .deliverImmediately)
        }
        return Token(name: name, id: id)
    }

    func cancel(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        handlers[token.name]?[token.id] = nil
        guard handlers[token.name]?.isEmpty ?? true else { return }
        handlers[token.name] = nil
        registeredNames.remove(token.name)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(DarwinNotificationCenter.shared).toOpaque(),
            CFNotificationName(token.name as CFString), nil)
    }

    private func fire(_ name: String) {
        lock.lock()
        let snapshot = handlers[name]?.values.map { $0 } ?? []
        lock.unlock()
        for handler in snapshot { handler() }
    }
}
