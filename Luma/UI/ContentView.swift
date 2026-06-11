import SwiftUI

struct ContentView: View {
    let dependencies: AppDependencies

    @AppStorage(AppearanceSettingsKey.accentHex)
    private var accentHex = ""
    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            Tab("Session", systemImage: "captions.bubble") {
                TranscriptSessionView(
                    store: dependencies.store,
                    session: dependencies.session,
                    overlay: dependencies.overlay,
                    exporter: dependencies.exporter)
            }
            Tab("Diagnostics", systemImage: "checklist") {
                CapabilityPanel(
                    capabilities: dependencies.capabilities,
                    languagePair: dependencies.store.languagePair)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Luma")
        .tint(Color(hexString: accentHex) ?? .accentColor)
        .appLanguage(appLanguageRaw)
    }
}
