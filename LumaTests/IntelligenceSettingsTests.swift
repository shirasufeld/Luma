import Foundation
import Testing

@testable import Luma

struct IntelligenceSettingsTests {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.intelligence.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func absentKeysDefaultBothAxesOn() {
        let options = IntelligenceSettings.proofreadOptions(from: makeDefaults())
        #expect(options.transcription)
        #expect(options.translation)
        #expect(options.isEnabled)
    }

    @Test func persistedFalseRoundTrips() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: IntelligenceSettingsKey.proofreadTranslation)
        let options = IntelligenceSettings.proofreadOptions(from: defaults)
        #expect(options.transcription)
        #expect(!options.translation)

        defaults.set(false, forKey: IntelligenceSettingsKey.proofreadTranscription)
        #expect(!IntelligenceSettings.proofreadOptions(from: defaults).isEnabled)
    }

    @Test func keysUseIntelligenceNamespace() {
        #expect(IntelligenceSettingsKey.proofreadTranscription == "intelligence.proofreadTranscription")
        #expect(IntelligenceSettingsKey.proofreadTranslation == "intelligence.proofreadTranslation")
    }
}
