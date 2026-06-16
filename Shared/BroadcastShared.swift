import AVFAudio
import Foundation

/// Constants shared by the main app (consumer) and the broadcast-upload
/// extension (producer) for the iOS system-audio captioning path.
///
/// The extension captures other apps' audio via ReplayKit, forwards raw PCM
/// through an App Group ring buffer, and the main app transcribes it — see
/// `docs/architecture.md §iOS 系统级音频`.
///
/// Identifiers (App Group, extension id, notification names) are **derived from
/// the app's bundle id at runtime** so no signing identity is baked into the
/// committed source. They line up with the entitlements, which use
/// `group.$(PRODUCT_BUNDLE_IDENTIFIER)` on the app and
/// `group.$(PRODUCT_BUNDLE_IDENTIFIER:base)` on the extension (both resolve to
/// `group.<host app id>`).
///
/// `nonisolated` so both processes can read these off the main actor (the app
/// target defaults to `@MainActor` isolation).
nonisolated enum BroadcastAudio {
    /// The broadcast-upload extension's bundle id is the host app id plus this.
    static let extensionBundleSuffix = "BroadcastExtension"

    /// The host app's bundle id. In the extension process `Bundle.main` is the
    /// appex, so strip the suffix to recover the containing app's id; both
    /// processes therefore compute the same value.
    static var hostAppBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        let suffix = ".\(extensionBundleSuffix)"
        return id.hasSuffix(suffix) ? String(id.dropLast(suffix.count)) : id
    }

    /// App Group shared by both processes — `group.<host app id>`. Registering
    /// it needs the paid Apple Developer Program.
    static var appGroupID: String { "group.\(hostAppBundleID)" }

    /// The extension's bundle id, used as the picker's `preferredExtension` so
    /// the system starts our extension directly.
    static var preferredExtensionID: String { "\(hostAppBundleID).\(extensionBundleSuffix)" }

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
    /// Namespaced by the host app id (unique per install) and identical in both
    /// processes since both derive the same id.
    nonisolated enum Notification {
        static var started: String { "\(BroadcastAudio.hostAppBundleID).broadcast.started" }
        static var finished: String { "\(BroadcastAudio.hostAppBundleID).broadcast.finished" }
        static var audio: String { "\(BroadcastAudio.hostAppBundleID).broadcast.audio" }
    }
}
