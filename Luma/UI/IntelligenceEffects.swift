import SwiftUI

/// Shared visual vocabulary for Apple-Intelligence-backed features: the
/// aurora palette, the processing glow, and the proofread boundary divider.
nonisolated enum AIGlowPalette {
    /// Aurora colors in sweep order; first == last for a seamless angular loop.
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .blue]

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// Apple-Intelligence-style processing glow: an angular gradient sweeping
/// around the container while active. Purely decorative — mounted only while
/// active (HIG: a process indicator, not a badge) and hidden from hit
/// testing and accessibility. Reduce Motion gets a static stroke.
private struct AIProcessingGlow: ViewModifier {
    let active: Bool
    var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    glow.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: active)
    }

    @ViewBuilder
    private var glow: some View {
        if reduceMotion {
            strokes(angle: .degrees(0))
                .opacity(0.55)
        } else {
            TimelineView(.animation) { context in
                let period: Double = 2.6
                let phase =
                    context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                strokes(angle: .degrees(phase * 360))
            }
        }
    }

    private func strokes(angle: Angle) -> some View {
        let gradient = AngularGradient(
            colors: AIGlowPalette.colors, center: .center, angle: angle)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.strokeBorder(gradient, lineWidth: 3)
                .blur(radius: 6)
            shape.strokeBorder(gradient, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Wraps this view in the Apple-Intelligence processing glow while
    /// `active`; costs nothing when idle.
    func aiProcessingGlow(_ active: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(AIProcessingGlow(active: active, cornerRadius: cornerRadius))
    }
}

/// The "proofread up to here" divider between corrected history and the
/// still-live tail of the transcript.
struct ProofreadBoundaryDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Label("Proofread up to here", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        AIGlowPalette.linear
            .opacity(0.35)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
