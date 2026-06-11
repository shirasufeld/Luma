import SwiftUI

struct ContentView: View {
    let dependencies: AppDependencies

    var body: some View {
        TabView {
            Tab("Session", systemImage: "captions.bubble") {
                TranscriptSessionView(store: dependencies.store, session: dependencies.session)
            }
            Tab("Diagnostics", systemImage: "checklist") {
                CapabilityPanel(capabilities: dependencies.capabilities)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Luma")
    }
}
