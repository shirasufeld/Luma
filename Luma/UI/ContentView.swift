import SwiftUI

struct ContentView: View {
    let dependencies: AppDependencies

    @AppStorage(AppearanceSettingsKey.accentHex)
    private var accentHex = ""
    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.system.rawValue

    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        let base =
            tabs
            .tint(Color(hexString: accentHex) ?? .accentColor)
            .appLanguage(appLanguageRaw)
        #if os(macOS)
        base
            .frame(minWidth: 560, minHeight: 400)
            .navigationTitle("Luma")
        #else
        base
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView(
                        store: dependencies.store, capabilities: dependencies.capabilities
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
                }
            }
            // Captions float over other apps via Picture in Picture; the PiP
            // source layer is mounted here (tiny/hidden — PiP reads its enqueued
            // frames, not its on-screen size).
            .background {
                dependencies.overlay.pipLayerHost
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        #endif
    }

    private var tabs: some View {
        TabView {
            Tab("Session", systemImage: "captions.bubble") {
                sessionTab
            }
            Tab("Diagnostics", systemImage: "checklist") {
                CapabilityPanel(
                    capabilities: dependencies.capabilities,
                    languagePair: dependencies.store.languagePair)
            }
        }
    }

    @ViewBuilder
    private var sessionTab: some View {
        #if os(iOS)
        NavigationStack {
            sessionView
                .navigationTitle("Luma")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
                }
        }
        #else
        sessionView
        #endif
    }

    private var sessionView: some View {
        TranscriptSessionView(
            store: dependencies.store,
            session: dependencies.session,
            overlay: dependencies.overlay,
            exporter: dependencies.exporter)
    }
}
