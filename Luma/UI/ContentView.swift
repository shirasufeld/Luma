import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Luma")
                .font(.largeTitle.weight(.semibold))
            Text("Real-time captions and on-device translation")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
