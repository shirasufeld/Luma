import Foundation
import Testing

@testable import Luma

struct ProofreadPresetTests {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.presets.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func presetsRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let presets = [
            ProofreadPreset(id: UUID(), name: "Physics", content: "quark, lepton"),
            ProofreadPreset(id: UUID(), name: "人名", content: "王小明、艾因斯沃斯博士"),
        ]
        ProofreadPresetStore.save(presets, to: defaults)
        #expect(ProofreadPresetStore.presets(from: defaults) == presets)
    }

    @Test func missingOrGarbageDataYieldsEmpty() {
        let defaults = makeDefaults()
        #expect(ProofreadPresetStore.presets(from: defaults) == [])
        defaults.set(Data("not json".utf8), forKey: IntelligenceSettingsKey.proofreadPresets)
        #expect(ProofreadPresetStore.presets(from: defaults) == [])
    }

    @Test func activePresetResolvesByID() {
        let defaults = makeDefaults()
        let preset = ProofreadPreset(id: UUID(), name: "A", content: "terms")
        ProofreadPresetStore.save([preset], to: defaults)
        defaults.set(
            preset.id.uuidString, forKey: IntelligenceSettingsKey.activeProofreadPresetID)
        #expect(ProofreadPresetStore.activePreset(from: defaults) == preset)
    }

    @Test func staleOrAbsentActiveIDYieldsNil() {
        let defaults = makeDefaults()
        let preset = ProofreadPreset(id: UUID(), name: "A", content: "terms")
        ProofreadPresetStore.save([preset], to: defaults)
        #expect(ProofreadPresetStore.activePreset(from: defaults) == nil)
        defaults.set(UUID().uuidString, forKey: IntelligenceSettingsKey.activeProofreadPresetID)
        #expect(ProofreadPresetStore.activePreset(from: defaults) == nil)
    }

    @Test func normalizedContentTrimsAndCollapsesBlankLines() {
        let raw = "  line one \n\n\n\nline two\n\n"
        #expect(ProofreadPresetStore.normalizedContent(raw) == "line one\n\nline two")
    }

    @Test func capAcceptsSmallAndRejectsOversizedContent() {
        let ok = String(repeating: "词", count: 250)
        let over = String(repeating: "词", count: 400)
        #expect(ProofreadPresetStore.isWithinCap(ok))
        #expect(!ProofreadPresetStore.isWithinCap(over))
    }

    @Test func injectionContentIsHardTruncatedToCap() {
        let over = String(repeating: "词", count: 400)
        let truncated = ProofreadPresetStore.injectionContent(over)
        #expect(
            IntelligenceChunker.estimatedTokens(truncated)
                <= ProofreadPresetStore.maxContentTokens)
        #expect(!truncated.isEmpty)
        // Within-cap content passes through (normalized) unchanged.
        #expect(ProofreadPresetStore.injectionContent("ok") == "ok")
    }
}
