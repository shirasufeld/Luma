import Foundation
import SwiftUI

/// In-app display language. "system" follows the OS; a concrete language id
/// switches the UI live (no relaunch) by overriding the SwiftUI locale
/// environment, which re-resolves every `Text`/`LocalizedStringKey` against
/// the string catalog.
nonisolated enum AppLanguage {
    static let defaultsKey = "app.language"
    /// Stored value meaning "follow the system language". Any other stored
    /// value is a locale identifier (kept from the previous enum's raw
    /// values, so old installs stay compatible).
    static let systemValue = "system"

    /// Languages the app ships UI translations for, with their endonyms
    /// (always shown in their own script, never localized).
    static let available: [(id: String, endonym: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
    ]

    static func locale(forStoredValue raw: String) -> Locale {
        guard raw != systemValue, !raw.isEmpty else { return Locale.autoupdatingCurrent }
        return Locale(identifier: raw)
    }

    /// The effective app locale right now — for code paths outside the
    /// SwiftUI environment (`String(localized:locale:)` call sites like the
    /// PiP placeholder and error messages).
    static func currentLocale() -> Locale {
        locale(forStoredValue: UserDefaults.standard.string(forKey: defaultsKey) ?? systemValue)
    }

    /// The best custom-language default when the user switches away from
    /// "System": the current system language if the app ships it, else en.
    static func defaultCustomID() -> String {
        // BCP-47 form ("zh-Hans-CN", "ja-JP"), unlike Locale.identifier.
        let preferred = Locale.preferredLanguages.first ?? "en"
        let match = available.first { entry in
            preferred == entry.id || preferred.hasPrefix("\(entry.id)-")
        }
        return match?.id ?? "en"
    }
}

extension View {
    /// Applies the user-selected app language to this view tree.
    func appLanguage(_ storedValue: String) -> some View {
        environment(\.locale, AppLanguage.locale(forStoredValue: storedValue))
    }
}
