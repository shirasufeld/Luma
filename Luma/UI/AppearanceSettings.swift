import AppKit
import SwiftUI

/// UserDefaults keys for in-window transcript appearance.
nonisolated enum AppearanceSettingsKey {
    static let transcriptFontSize = "window.transcriptFontSize"
    /// Hex sRGB string ("#RRGGBB"); empty means the system accent color.
    static let accentHex = "window.accentHex"

    static let defaultTranscriptFontSize: Double = 13
}

extension Color {
    /// Parses "#RRGGBB" (sRGB). Returns nil for anything else.
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// "#RRGGBB" in sRGB, or nil when the color can't be converted.
    var hexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
