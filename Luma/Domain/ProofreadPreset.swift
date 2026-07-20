import Foundation

/// One user-authored glossary/reference preset for smart proofread: names,
/// technical terms, and background notes likely to occur in a talk. The
/// active preset's content is injected into the proofread instructions.
nonisolated struct ProofreadPreset: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var content: String
}

/// Flat-defaults persistence for presets (JSON array under one key, active
/// preset by ID under another) plus the system content cap that keeps the
/// injected reference inside the on-device context window.
nonisolated enum ProofreadPresetStore {

    /// System cap on one preset's content, in estimated tokens (≈ CJK
    /// characters). Sized against the ~4096 window: instructions ~350 +
    /// reference ≤300 + carried context ≤150 + input + echo-all output must
    /// all fit. Not user-adjustable.
    static let maxContentTokens = 300

    static func presets(from defaults: UserDefaults = .standard) -> [ProofreadPreset] {
        guard let data = defaults.data(forKey: IntelligenceSettingsKey.proofreadPresets),
            let presets = try? JSONDecoder().decode([ProofreadPreset].self, from: data)
        else { return [] }
        return presets
    }

    static func save(_ presets: [ProofreadPreset], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: IntelligenceSettingsKey.proofreadPresets)
    }

    /// The preset selected for injection; nil when none is selected or the
    /// stored ID no longer resolves (deleted preset).
    static func activePreset(from defaults: UserDefaults = .standard) -> ProofreadPreset? {
        guard
            let raw = defaults.string(forKey: IntelligenceSettingsKey.activeProofreadPresetID),
            let id = UUID(uuidString: raw)
        else { return nil }
        return presets(from: defaults).first { $0.id == id }
    }

    /// Trims every line and collapses runs of blank lines to one.
    static func normalizedContent(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    static func isWithinCap(_ content: String) -> Bool {
        IntelligenceChunker.estimatedTokens(content) <= maxContentTokens
    }

    /// What actually gets injected: normalized, and defensively hard-truncated
    /// to the cap in case over-cap content ever reaches persistence.
    static func injectionContent(_ raw: String) -> String {
        let normalized = normalizedContent(raw)
        guard !isWithinCap(normalized) else { return normalized }
        var kept = ""
        for character in normalized {
            let candidate = kept + String(character)
            if IntelligenceChunker.estimatedTokens(candidate) > maxContentTokens { break }
            kept = candidate
        }
        return kept
    }
}
