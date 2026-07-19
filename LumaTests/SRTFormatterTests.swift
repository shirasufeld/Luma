import Foundation
import Testing

@testable import Luma

struct SRTFormatterTests {

    @Test func timecodeFormatting() {
        #expect(SRTFormatter.timecode(0) == "00:00:00,000")
        #expect(SRTFormatter.timecode(3661.5) == "01:01:01,500")
        #expect(SRTFormatter.timecode(59.999) == "00:00:59,999")
    }

    @Test func srtDocumentStructure() {
        let first = SubtitleEntry(
            segment: makeSegment("Hello world", start: 0.5, end: 2.0),
            translation: .translated("你好，世界"))
        let second = SubtitleEntry(
            segment: makeSegment("Second line", start: 2.5, end: 4.25))
        let document = SRTFormatter.srtDocument(entries: [first, second])

        let expected = """
            1
            00:00:00,500 --> 00:00:02,000
            Hello world
            你好，世界

            2
            00:00:02,500 --> 00:00:04,250
            Second line

            """
        #expect(document == expected)
    }

    @Test func degenerateRangeGetsMinimumHold() {
        let entry = SubtitleEntry(segment: makeSegment("blip", start: 3.0, end: 3.0))
        let document = SRTFormatter.srtDocument(entries: [entry])
        #expect(document.contains("00:00:03,000 --> 00:00:04,500"))
    }

    @Test func translationsCanBeExcluded() {
        let entry = SubtitleEntry(
            segment: makeSegment("Hi", start: 0, end: 1),
            translation: .translated("嗨"))
        let document = SRTFormatter.srtDocument(entries: [entry], includeTranslations: false)
        #expect(!document.contains("嗨"))
    }

    @Test func textDocumentJoinsEntries() {
        let entries = [
            SubtitleEntry(
                segment: makeSegment("One", start: 0, end: 1),
                translation: .translated("一")),
            SubtitleEntry(segment: makeSegment("Two", start: 1, end: 2)),
        ]
        let document = SRTFormatter.textDocument(entries: entries)
        #expect(document == "One\n一\n\nTwo")
    }

    @Test func emptyEntriesProduceEmptyDocuments() {
        #expect(SRTFormatter.srtDocument(entries: []) == "")
        #expect(SRTFormatter.textDocument(entries: []) == "")
    }

    @Test func documentsPreferProofreadCorrections() {
        var entry = SubtitleEntry(
            segment: makeSegment("helo", start: 0, end: 1),
            translation: .translated("哈喽"))
        entry.correctedText = ProofreadCorrection(text: "hello", batchID: UUID())
        entry.correctedTranslation = ProofreadCorrection(text: "你好", batchID: UUID())

        let text = SRTFormatter.textDocument(entries: [entry])
        #expect(text == "hello\n你好")

        let srt = SRTFormatter.srtDocument(entries: [entry])
        #expect(srt.contains("hello") && srt.contains("你好"))
        #expect(!srt.contains("helo\n") && !srt.contains("哈喽"))
        // Timecodes come from the untouched segment range.
        #expect(srt.contains("00:00:00,000 --> 00:00:01,000"))
    }
}
