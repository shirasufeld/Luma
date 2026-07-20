import Foundation

/// Pure math for the transcript's pinned-to-bottom tracking, separated from
/// the view so the formula is unit-testable; the view feeds it values from
/// `ScrollGeometry`.
nonisolated enum TranscriptScrollMetrics {

    /// Whether the viewport bottom is within `threshold` of the true content
    /// bottom (content plus its bottom margin). Elastic overscroll yields a
    /// negative distance and counts as pinned, as does content shorter than
    /// the container.
    static func isNearBottom(
        offsetY: CGFloat,
        containerHeight: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        let distanceToBottom = contentHeight + bottomInset - (offsetY + containerHeight)
        return distanceToBottom <= threshold
    }
}
