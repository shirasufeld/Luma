import SwiftUI

struct ContentView: View {
    let dependencies: AppDependencies

    var body: some View {
        CapabilityPanel(capabilities: dependencies.capabilities)
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle("Luma")
    }
}
