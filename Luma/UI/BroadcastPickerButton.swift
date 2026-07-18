#if os(iOS)
import ReplayKit
import SwiftUI
import UIKit

/// Wraps `RPSystemBroadcastPickerView` so SwiftUI can present the system
/// "Start Broadcast" button. Targeting our extension via `preferredExtension`
/// means one tap starts Luma's broadcast directly (no extension chooser); the
/// microphone toggle is hidden because we only caption other apps' audio.
struct BroadcastPickerButton: UIViewRepresentable {
    /// Must match the SwiftUI `.frame` the button is embedded with: the
    /// inner UIButton keeps the creation-time frame, so a mismatch leaves
    /// the glyph off-center against any backing shape (field bug: a 52 pt
    /// button squeezed into a 44 pt frame sat 4 pt off its backing circle).
    var size: CGFloat = 44

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        picker.preferredExtension = BroadcastAudio.preferredExtensionID
        picker.showsMicrophoneButton = false
        // The system control ships without a meaningful VoiceOver label, and
        // this is the single tap that starts system-audio capture.
        let label = String(localized: "Start System Audio Broadcast")
        let hint = String(localized: "Opens the system broadcast picker.")
        picker.accessibilityLabel = label
        picker.accessibilityHint = hint
        for case let button as UIButton in picker.subviews {
            button.frame = picker.bounds
            button.accessibilityLabel = label
            button.accessibilityHint = hint
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
#endif
