#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Drives the floating caption surface, using each platform's native idiom.
///
/// On macOS this is an AppKit bridge to a borderless, non-activating `NSPanel`
/// that floats above other windows and joins all Spaces. On iOS there is no
/// cross-app floating window, so captions float via Picture in Picture instead
/// (see `CaptionPiPController`). `isVisible` reflects whichever surface is up.
@MainActor
@Observable
final class SubtitleOverlayController {
    private let store: SessionStore
    #if os(macOS)
    private var panel: NSPanel?
    #else
    @ObservationIgnored private let pip = CaptionPiPController()
    #endif

    private(set) var isVisible = false

    init(store: SessionStore) {
        self.store = store
        #if os(iOS)
        pip.bind(store: store)
        // Mirror externally-driven PiP stops (user closes the PiP window).
        pip.onActiveChange = { [weak self] active in self?.isVisible = active }
        #endif
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        #if os(macOS)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        #else
        pip.start()
        #endif
        isVisible = true
    }

    func hide() {
        #if os(macOS)
        panel?.orderOut(nil)
        #else
        pip.stop()
        #endif
        isVisible = false
    }

    #if os(iOS)
    /// The hidden view hosting the PiP source layer; mounted by `ContentView`.
    var pipLayerHost: some View { CaptionPiPLayerView(layer: pip.displayLayer) }
    #endif

    #if os(macOS)
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: initialFrame(),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 80)
        panel.setFrameAutosaveName("LumaSubtitleOverlay")
        panel.contentView = NSHostingView(rootView: SubtitleOverlayView(store: store))
        panel.identifier = NSUserInterfaceItemIdentifier("LumaSubtitleOverlay")
        return panel
    }

    private func initialFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 120, width: 720, height: 130)
        }
        let visible = screen.visibleFrame
        let width = min(visible.width * 0.6, 900)
        let height: CGFloat = 130
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + 80,
            width: width,
            height: height)
    }
    #endif
}
