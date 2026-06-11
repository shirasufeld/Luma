import SwiftUI

/// Read-only diagnostics panel showing permission and model availability for
/// the active language pair. Temporary home in the main window until the
/// full workbench UI lands.
struct CapabilityPanel: View {
    let capabilities: any CapabilityChecking
    var languagePair: LanguagePair = .default

    @State private var snapshot = CapabilitySnapshot()
    @State private var isLoading = true

    var body: some View {
        Form {
            Section("Permissions") {
                row("Microphone", status: permissionLabel(snapshot.microphone))
                row("System Audio Capture", status: permissionLabel(snapshot.systemAudioCapture))
            }
            Section("Models") {
                row(
                    "Transcription (\(languagePair.transcriptionLocale.identifier))",
                    status: transcriptionLabel(snapshot.transcription)
                )
                row(
                    "Translation (\(languagePair.translationSource.minimalIdentifier) → \(languagePair.translationTarget.minimalIdentifier))",
                    status: translationLabel(snapshot.translation)
                )
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        var next = CapabilitySnapshot()
        next.microphone = capabilities.microphonePermission()
        next.transcription = await capabilities.transcriptionAvailability(
            for: languagePair.transcriptionLocale)
        next.translation = await capabilities.translationAvailability(
            from: languagePair.translationSource, to: languagePair.translationTarget)
        snapshot = next
    }

    private func row(_ title: String, status: (String, Color)) -> some View {
        LabeledContent(title) {
            Text(status.0)
                .foregroundStyle(status.1)
        }
    }

    private func permissionLabel(_ state: PermissionState) -> (String, Color) {
        switch state {
        case .granted: ("Granted", .green)
        case .denied: ("Denied", .red)
        case .notDetermined: ("Not determined", .secondary)
        }
    }

    private func transcriptionLabel(_ state: TranscriptionAvailability) -> (String, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .supported: ("Download required", .orange)
        case .unsupportedLocale: ("Locale unsupported", .red)
        case .unavailableOnDevice: ("Unavailable", .red)
        }
    }

    private func translationLabel(_ state: TranslationAvailability) -> (String, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .supported: ("Download required", .orange)
        case .unsupported: ("Pair unsupported", .red)
        }
    }
}
