import Foundation

/// Lifecycle of a captioning session.
nonisolated enum SessionState: Sendable, Equatable {
    case idle
    case preparing
    case running
    case paused
    case stopping
}

/// State of the active audio source.
nonisolated enum AudioInputState: Sendable, Equatable {
    case idle
    case capturing(AudioInputKind)
    case paused(AudioInputKind)
    case failed(String)
}
