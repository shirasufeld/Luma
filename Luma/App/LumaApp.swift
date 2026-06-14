import SwiftUI

@main
struct LumaApp: App {
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            ContentView(dependencies: dependencies)
        }

        #if os(macOS)
        // The Settings scene is macOS-only; iOS presents settings as an in-app
        // sheet from ContentView.
        Settings {
            SettingsView(store: dependencies.store, capabilities: dependencies.capabilities)
        }
        #endif
    }
}
