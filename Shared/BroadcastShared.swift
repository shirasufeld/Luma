import AVFAudio
import Foundation

/// Constants shared by the main app (consumer) and the broadcast-upload
/// extension (producer) for the iOS system-audio captioning path.
///
/// The extension captures other apps' audio via ReplayKit, forwards raw PCM
/// through an App Group ring buffer, and the main app transcribes it — see
/// `docs/architecture.md §iOS 系统级音频`.
///
/// `nonisolated` so both processes can read these constants/helpers off the
/// main actor (the app target defaults to `@MainActor` isolation).
nonisolated enum BroadcastAudio {
    /// App Group both processes share. Must match each target's entitlements.
    static let appGroupID = "group.com.example.Luma"

    /// The broadcast-upload extension's bundle id, used as the picker's
    /// `preferredExtension` so the system starts our extension directly.
    static let preferredExtensionID = "com.example.Luma.BroadcastExtension"

    /// Ring buffer file inside the App Group container.
    static let ringFileName = "broadcast-audio.ring"

    /// ~5.4 s of headroom at the canonical format; far below the extension's
    /// ~50 MB budget. A multiple of the page size keeps the mapping tidy.
    static let ringCapacityBytes = 1 << 20

    /// Canonical PCM the extension forwards and the app consumes. Mono keeps
    /// the payload light; the transcriber resamples downstream so the exact
    /// rate only needs to be lossless enough for speech.
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 1

    /// A fresh `AVAudioFormat` for the canonical PCM (interleaved mono Float32).
    static func makeCanonicalFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channelCount, interleaved: true)!
    }

    /// Ring buffer URL in the shared container, or `nil` when the App Group is
    /// unavailable (e.g. Simulator without the entitlement).
    static func ringURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(ringFileName)
    }

    /// Darwin notification names signalling broadcast lifecycle and new audio.
    nonisolated enum Notification {
        static let started = "com.example.Luma.broadcast.started"
        static let finished = "com.example.Luma.broadcast.finished"
        static let audio = "com.example.Luma.broadcast.audio"
    }
}
