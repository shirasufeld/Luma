#if os(iOS)
import ReplayKit
import SwiftUI
import UIKit

/// Wraps `RPSystemBroadcastPickerView` so SwiftUI can present the system
/// "Start Broadcast" button. Targeting our extension via `preferredExtension`
/// means one tap starts Luma's broadcast directly (no extension chooser); the
/// microphone toggle is hidden because we only caption other apps' audio.
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        picker.preferredExtension = BroadcastAudio.preferredExtensionID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
#endif
