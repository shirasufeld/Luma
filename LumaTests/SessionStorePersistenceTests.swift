import Foundation
import Testing

@testable import Luma

@MainActor
struct SessionStorePersistenceTests {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.store.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func inputKindAndLanguagePairRoundTrip() {
        let defaults = makeDefaults()
        let first = SessionStore(defaults: defaults)
        first.inputKind = .systemAudio
        first.languagePair = LanguagePair(
            transcriptionLocale: Locale(identifier: "ja-JP"),
            translationTarget: Locale.Language(identifier: "en"))
        first.translationMode = .accurate

        let second = SessionStore(defaults: defaults)
        #expect(second.inputKind == .systemAudio)
        #expect(second.languagePair.transcriptionLocale.identifier == "ja-JP")
        #expect(second.languagePair.translationTarget?.minimalIdentifier == "en")
        #expect(second.translationMode == .accurate)
    }

    @Test func noneTranslationTargetRoundTrips() {
        let defaults = makeDefaults()
        let first = SessionStore(defaults: defaults)
        first.languagePair.translationTarget = nil

        let second = SessionStore(defaults: defaults)
        #expect(second.languagePair.translationTarget == nil)
        #expect(!second.languagePair.isTranslationEnabled)
    }

    @Test func languageKeysRestoreIndependently() {
        // One missing key must never discard the other's persisted value.
        let defaults = makeDefaults()
        defaults.set("ko-KR", forKey: "language.transcriptionLocale")
        let store = SessionStore(defaults: defaults)
        #expect(store.languagePair.transcriptionLocale.identifier == "ko-KR")
        #expect(store.languagePair.translationTarget == LanguagePair.default.translationTarget)
    }

    @Test func freshDefaultsFallBackToDefaults() {
        let store = SessionStore(defaults: makeDefaults())
        #expect(store.inputKind == .microphone)
        #expect(store.languagePair == .default)
        #expect(store.translationMode == .balanced)
    }

    @Test func garbageValuesFallBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: "audio.inputKind")
        defaults.set("interpretive-dance", forKey: "translation.mode")
        let store = SessionStore(defaults: defaults)
        #expect(store.inputKind == .microphone)
        #expect(store.translationMode == .balanced)
    }
}
