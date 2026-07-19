import Foundation
import Testing

@testable import Luma

struct PunctuationNormalizerTests {

    private func sentence(_ text: String) -> ProofreadSentence {
        ProofreadSentence(id: UUID(), text: text)
    }

    @Test func leadingStrayMovesToPreviousSentenceInScope() {
        let a = sentence("这里有一个交流电源")
        let b = sentence("。而当电流方向反过来的时候")
        let (normalized, changes) = PunctuationNormalizer.normalize([a, b])
        #expect(normalized.map(\.text) == ["这里有一个交流电源。", "而当电流方向反过来的时候"])
        #expect(changes == [a.id: "这里有一个交流电源。", b.id: "而当电流方向反过来的时候"])
    }

    @Test func firstSentenceHandsStrayAcrossBoundary() {
        let previous = sentence("上一句还没有结尾")
        let first = sentence("。这时候我们放置一个金属网")
        let (normalized, changes) = PunctuationNormalizer.normalize([first], previous: previous)
        #expect(normalized.map(\.text) == ["这时候我们放置一个金属网"])
        #expect(changes[previous.id] == "上一句还没有结尾。")
        #expect(changes[first.id] == "这时候我们放置一个金属网")
    }

    @Test func strayIsDroppedWhenReceiverAlreadyTerminated() {
        let previous = sentence("上一句已经结束。")
        let first = sentence("。新的一句")
        let (normalized, changes) = PunctuationNormalizer.normalize([first], previous: previous)
        #expect(normalized.map(\.text) == ["新的一句"])
        #expect(changes[previous.id] == nil)
        #expect(changes[first.id] == "新的一句")
    }

    @Test func strayWithNoReceiverIsDropped() {
        let only = sentence(", so the current will flow")
        let (normalized, changes) = PunctuationNormalizer.normalize([only])
        #expect(normalized.map(\.text) == ["so the current will flow"])
        #expect(changes[only.id] == "so the current will flow")
    }

    @Test func latinStrayAttachesToLatinSentence() {
        let a = sentence("the circuit forms a loop")
        let b = sentence(". When the direction is reversed")
        let (normalized, _) = PunctuationNormalizer.normalize([a, b])
        #expect(normalized.map(\.text) == ["the circuit forms a loop.", "When the direction is reversed"])
    }

    @Test func arabicAndDevanagariStraysAreRecognized() {
        let a = sentence("هذه جملة أولى")
        let b = sentence("؟ وهذه جملة ثانية")
        let (arabic, _) = PunctuationNormalizer.normalize([a, b])
        #expect(arabic.map(\.text) == ["هذه جملة أولى؟", "وهذه جملة ثانية"])

        let c = sentence("यह पहला वाक्य है")
        let d = sentence("। यह दूसरा वाक्य है")
        let (hindi, _) = PunctuationNormalizer.normalize([c, d])
        #expect(hindi.map(\.text) == ["यह पहला वाक्य है।", "यह दूसरा वाक्य है"])
    }

    @Test func spanishOpeningMarksAreNotStrays() {
        let a = sentence("vamos a empezar")
        let b = sentence("¿qué hora es?")
        let (normalized, changes) = PunctuationNormalizer.normalize([a, b])
        #expect(normalized.map(\.text) == ["vamos a empezar", "¿qué hora es?"])
        #expect(changes.isEmpty)
    }

    @Test func punctuationOnlySentenceIsLeftAlone() {
        let only = sentence("。")
        let (normalized, changes) = PunctuationNormalizer.normalize([only])
        #expect(normalized.map(\.text) == ["。"])
        #expect(changes.isEmpty)
    }

    @Test func cleanInputProducesNoChanges() {
        let a = sentence("一切正常的句子。")
        let b = sentence("第二句也正常。")
        let (normalized, changes) = PunctuationNormalizer.normalize([a, b])
        #expect(normalized.map(\.text) == [a.text, b.text])
        #expect(changes.isEmpty)
    }
}
