import AppKit
import SwiftUI

/// AppKit bridge for the floating caption window: a borderless,
/// non-activating panel that floats above other windows, joins all Spaces
/// (including full-screen apps), and can be dragged or resized directly.
@MainActor
@Observable
final class SubtitleOverlayController {
    private let store: SessionStore
    private var panel: NSPanel?

    private(set) var isVisible = false

    init(store: SessionStore) {
        self.store = store
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

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
}
