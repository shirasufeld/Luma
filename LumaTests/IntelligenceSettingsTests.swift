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
        #expect(IntelligenceSettingsKey.proofreadPresets == "intelligence.proofreadPresets")
        #expect(
            IntelligenceSettingsKey.activeProofreadPresetID
                == "intelligence.activeProofreadPresetID")
    }

    @Test func activePresetContentFlowsIntoOptionsNormalized() {
        let defaults = makeDefaults()
        let preset = ProofreadPreset(id: UUID(), name: "Bio", content: "  CRISPR \n\n\n\ncas9  ")
        ProofreadPresetStore.save([preset], to: defaults)
        defaults.set(
            preset.id.uuidString, forKey: IntelligenceSettingsKey.activeProofreadPresetID)
        #expect(IntelligenceSettings.proofreadOptions(from: defaults).reference == "CRISPR\n\ncas9")
    }

    @Test func noActiveOrEmptyPresetYieldsNilReference() {
        let defaults = makeDefaults()
        #expect(IntelligenceSettings.proofreadOptions(from: defaults).reference == nil)

        let blank = ProofreadPreset(id: UUID(), name: "Blank", content: "   \n\n  ")
        ProofreadPresetStore.save([blank], to: defaults)
        defaults.set(blank.id.uuidString, forKey: IntelligenceSettingsKey.activeProofreadPresetID)
        #expect(IntelligenceSettings.proofreadOptions(from: defaults).reference == nil)
    }
}
