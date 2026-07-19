import Foundation
import Testing

@testable import Luma

struct IntelligenceValidationTests {

    @Test func validationDropsOutOfRangeEmptyIdenticalAndBloatedCorrections() {
        let sentences = ["short one", "第二句话在这里"]
        let raw: [(index: Int, text: String)] = [
            (index: 0, text: "x"),
            (index: 3, text: "x"),
            (index: 1, text: "   "),
            (index: 2, text: "第二句话在这里"),
            (index: 1, text: String(repeating: "spam ", count: 40)),
        ]
        #expect(AppleIntelligenceService.validatedCorrections(raw, against: sentences).isEmpty)
    }

    @Test func validationKeepsPlausibleCorrections() {
        let sentences = ["short one", "第二句话在这里"]
        let raw: [(index: Int, text: String)] = [
            (index: 1, text: "short two"),
            (index: 2, text: "第二句话在这儿"),
        ]
        let validated = AppleIntelligenceService.validatedCorrections(raw, against: sentences)
        #expect(validated == [1: "short two", 2: "第二句话在这儿"])
    }

    @Test func validationTrimsWhitespaceBeforeComparing() {
        let validated = AppleIntelligenceService.validatedCorrections(
            [(index: 1, text: "  fixed  ")], against: ["broken"])
        #expect(validated == [1: "fixed"])
    }

    @Test func validationCollapsesNewlinesToOneLine() {
        let validated = AppleIntelligenceService.validatedCorrections(
            [(index: 1, text: "fixed\nacross\n\nlines")], against: ["broken text here"])
        #expect(validated == [1: "fixed across lines"])
    }
}
