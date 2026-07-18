import SwiftUI

/// Minimal five-bar input-level indicator for the status bar: instant visual
/// confirmation that audio is (or is not) reaching the pipeline.
struct AudioLevelMeter: View {
    var level: Float?

    /// Per-bar multipliers give the classic center-weighted silhouette.
    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.4]
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.weights.count, id: \.self) { index in
                Capsule()
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: Self.maxBarHeight)
        .foregroundStyle(level == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel(Text("Audio level"))
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard let level else { return Self.minBarHeight }
        let span = Self.maxBarHeight - Self.minBarHeight
        return Self.minBarHeight + span * Self.weights[index] * CGFloat(level)
    }
}
