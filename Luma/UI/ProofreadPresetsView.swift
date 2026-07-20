import SwiftUI

/// Management sheet for glossary/reference presets: list, add, edit, delete.
/// Choosing the *active* preset happens in the main screen's Smart Proofread
/// menu, next to where proofreading is triggered.
struct ProofreadPresetsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.systemValue
    @AppStorage(IntelligenceSettingsKey.proofreadPresets)
    private var presetsData = Data()
    @AppStorage(IntelligenceSettingsKey.activeProofreadPresetID)
    private var activePresetID = ""

    /// Non-nil while the editor sheet is up; `id` decides update-vs-append.
    @State private var editing: ProofreadPreset?

    private var presets: [ProofreadPreset] {
        (try? JSONDecoder().decode([ProofreadPreset].self, from: presetsData)) ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if presets.isEmpty {
                    Text(
                        "No presets yet. Add names, technical terms, and notes to guide proofreading."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(presets) { preset in
                            Button {
                                editing = preset
                            } label: {
                                presetRow(preset)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Glossary & Reference")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("New Preset", systemImage: "plus") {
                        editing = ProofreadPreset(id: UUID(), name: "", content: "")
                    }
                }
            }
        }
        .sheet(item: $editing) { preset in
            PresetEditor(
                draft: preset,
                isNew: !presets.contains { $0.id == preset.id },
                onSave: { upsert($0) },
                onDelete: { delete(id: $0) })
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 340, idealHeight: 440)
        #endif
        .appLanguage(appLanguageRaw)
    }

    private func presetRow(_ preset: ProofreadPreset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: preset.name)
            if let firstLine = preset.content.split(separator: "\n").first {
                Text(verbatim: String(firstLine))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func upsert(_ preset: ProofreadPreset) {
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) {
            updated[index] = preset
        } else {
            updated.append(preset)
        }
        write(updated)
    }

    private func delete(id: UUID) {
        write(presets.filter { $0.id != id })
        if activePresetID == id.uuidString { activePresetID = "" }
    }

    private func write(_ presets: [ProofreadPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        presetsData = data
    }
}

/// Editor form for one preset. Save is gated on the system content cap so
/// over-window references never reach persistence.
private struct PresetEditor: View {
    @State var draft: ProofreadPreset
    let isNew: Bool
    let onSave: (ProofreadPreset) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var estimatedTokens: Int { IntelligenceChunker.estimatedTokens(draft.content) }
    private var overCap: Bool { !ProofreadPresetStore.isWithinCap(draft.content) }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name)
                Section("Reference Content") {
                    TextEditor(text: $draft.content)
                        .font(.body)
                        .frame(minHeight: 140)
                    HStack {
                        if overCap {
                            Text("Too long for the on-device model — shorten it.")
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        if !draft.content.isEmpty {
                            Text(verbatim: "≈ \(estimatedTokens)/\(ProofreadPresetStore.maxContentTokens)")
                                .monospacedDigit()
                                .foregroundStyle(overCap ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                    }
                    .font(.callout)
                }
                if !isNew {
                    Button("Delete Preset", role: .destructive) {
                        onDelete(draft.id)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.name = trimmedName
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || overCap)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: 400)
        #endif
    }
}
