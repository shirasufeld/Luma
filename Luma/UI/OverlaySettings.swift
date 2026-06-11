import SwiftUI

/// UserDefaults-backed overlay appearance settings, shared between the
/// Settings pane and the overlay view via `@AppStorage`.
nonisolated enum OverlaySettingsKey {
    static let fontSize = "overlay.fontSize"
    static let surface = "overlay.surface"
    static let showOriginal = "overlay.showOriginal"
    static let showTranslation = "overlay.showTranslation"

    static let defaultFontSize: Double = 28
}

/// Visual treatment of the subtitle surface. Liquid Glass is the macOS 26+
/// default; solid is both a user choice and the automatic fallback when
/// Reduce Transparency is on.
nonisolated enum OverlaySurfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case liquidGlass
    case material
    case solid

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .material: "Material"
        case .solid: "Solid"
        }
    }
}
