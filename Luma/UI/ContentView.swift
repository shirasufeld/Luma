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
            .fullScreenCover(isPresented: overlayPresented) {
                captionOverlay
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

    #if os(iOS)
    /// iOS has no cross-app floating window, so the caption "overlay" is a
    /// full-screen in-app surface (e.g. lay the device flat for a table read).
    private var overlayPresented: Binding<Bool> {
        Binding(
            get: { dependencies.overlay.isVisible },
            set: { if !$0 { dependencies.overlay.hide() } })
    }

    private var captionOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SubtitleOverlayView(store: dependencies.store)
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark.circle.fill") {
                dependencies.overlay.hide()
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .tint(.white)
            .padding()
        }
    }
    #endif
}
