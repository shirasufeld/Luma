import Foundation
import Testing

@testable import Luma

struct TranscriptScrollMetricsTests {

    @Test func exactBottomIsPinned() {
        #expect(
            TranscriptScrollMetrics.isNearBottom(
                offsetY: 600, containerHeight: 400, contentHeight: 1000,
                bottomInset: 0, threshold: 56))
    }

    @Test func withinThresholdIsPinned() {
        #expect(
            TranscriptScrollMetrics.isNearBottom(
                offsetY: 550, containerHeight: 400, contentHeight: 1000,
                bottomInset: 0, threshold: 56))
    }

    @Test func aboveThresholdIsNotPinned() {
        #expect(
            !TranscriptScrollMetrics.isNearBottom(
                offsetY: 500, containerHeight: 400, contentHeight: 1000,
                bottomInset: 0, threshold: 56))
    }

    @Test func bottomInsetExtendsTheScrollableRange() {
        // With a 72pt bottom margin the true bottom sits 72pt further down;
        // sitting at the un-inset bottom is still within a 56pt threshold? No:
        // distance = 1000 + 72 − (600 + 400) = 72 > 56.
        #expect(
            !TranscriptScrollMetrics.isNearBottom(
                offsetY: 600, containerHeight: 400, contentHeight: 1000,
                bottomInset: 72, threshold: 56))
        #expect(
            TranscriptScrollMetrics.isNearBottom(
                offsetY: 672, containerHeight: 400, contentHeight: 1000,
                bottomInset: 72, threshold: 56))
    }

    @Test func elasticOverscrollBeyondBottomIsPinned() {
        #expect(
            TranscriptScrollMetrics.isNearBottom(
                offsetY: 700, containerHeight: 400, contentHeight: 1000,
                bottomInset: 0, threshold: 56))
    }

    @Test func contentShorterThanContainerIsPinned() {
        #expect(
            TranscriptScrollMetrics.isNearBottom(
                offsetY: 0, containerHeight: 400, contentHeight: 200,
                bottomInset: 0, threshold: 56))
    }
}
