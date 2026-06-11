import SwiftUI

/// In-app display language. `system` follows macOS; explicit choices switch
/// the UI live (no relaunch) by overriding the SwiftUI locale environment,
/// which re-resolves every `Text`/`LocalizedStringKey` against the string
/// catalog.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "app.language"

    var id: String { rawValue }

    /// nil means "follow the system language".
    var localeOverride: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    static func locale(forStoredValue raw: String) -> Locale {
        AppLanguage(rawValue: raw)?.localeOverride ?? Locale.autoupdatingCurrent
    }
}

extension View {
    /// Applies the user-selected app language to this view tree.
    func appLanguage(_ storedValue: String) -> some View {
        environment(\.locale, AppLanguage.locale(forStoredValue: storedValue))
    }
}
