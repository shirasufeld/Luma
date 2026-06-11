import CoreMedia
import Foundation
import Testing

@testable import Luma

struct SubtitleBufferTests {

    @Test func volatileIsReplacedByFinalized() {
        var buffer = SubtitleBuffer()
        buffer.applyVolatile(
            text: AttributedString("hel"),
            range: CMTimeRange(
                start: .zero, end: CMTime(seconds: 1, preferredTimescale: 600)))
        #expect(buffer.volatileText != nil)

        buffer.applyFinalized(makeSegment("hello", start: 0, end: 1.2))
        #expect(buffer.volatileText == nil)
        #expect(buffer.entries.count == 1)
        #expect(buffer.entries[0].segment.plainText == "hello")
    }

    @Test func duplicateSegmentIDIsDropped() {
        var buffer = SubtitleBuffer()
        let segment = makeSegment("once", start: 0, end: 1)
        let firstApply = buffer.applyFinalized(segment)
        let secondApply = buffer.applyFinalized(segment)
        #expect(firstApply)
        #expect(!secondApply)
        #expect(buffer.entries.count == 1)
    }

    @Test func duplicateRangeAndTextIsDropped() {
        var buffer = SubtitleBuffer()
        let firstApply = buffer.applyFinalized(makeSegment("same", start: 0, end: 1))
        // Different ID, identical audio range and text: a re-finalization.
        let secondApply = buffer.applyFinalized(makeSegment("same", start: 0, end: 1))
        #expect(firstApply)
        #expect(!secondApply)
        #expect(buffer.entries.count == 1)
    }

    @Test func sameTextLaterRangeIsKept() {
        var buffer = SubtitleBuffer()
        let firstApply = buffer.applyFinalized(makeSegment("again", start: 0, end: 1))
        // The speaker genuinely repeated the phrase later.
        let secondApply = buffer.applyFinalized(makeSegment("again", start: 5, end: 6))
        #expect(firstApply)
        #expect(secondApply)
        #expect(buffer.entries.count == 2)
    }

    @Test func emptyOrWhitespaceSegmentIsRejected() {
        var buffer = SubtitleBuffer()
        let appended = buffer.applyFinalized(makeSegment("   ", start: 0, end: 1))
        #expect(!appended)
        #expect(buffer.entries.isEmpty)
    }

    @Test func translationBackfillTargetsCorrectEntry() {
        var buffer = SubtitleBuffer()
        let first = makeSegment("one", start: 0, end: 1)
        let second = makeSegment("two", start: 1, end: 2)
        buffer.applyFinalized(first)
        buffer.applyFinalized(second)

        buffer.applyTranslation(segmentID: second.id, state: .translated("二"))
        #expect(buffer.entries[0].translation == .pending)
        #expect(buffer.entries[1].translation == .translated("二"))
    }

    @Test func clearRemovesEverything() {
        var buffer = SubtitleBuffer()
        buffer.applyFinalized(makeSegment("x", start: 0, end: 1))
        buffer.applyVolatile(text: AttributedString("y"), range: .invalid)
        buffer.clear()
        #expect(buffer.entries.isEmpty)
        #expect(buffer.volatileText == nil)
    }
}
