import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Read-only diagnostics panel showing permission and model availability for
/// the active language pair. Temporary home in the main window until the
/// full workbench UI lands.
struct CapabilityPanel: View {
    let capabilities: any CapabilityChecking
    var languagePair: LanguagePair = .default
    #if os(iOS)
    /// Live broadcast state for the system-audio row — on iOS system audio
    /// arrives via the broadcast extension, which has no permission concept.
    var broadcastMonitor: BroadcastStateMonitor? = nil
    #endif

    @State private var snapshot = CapabilitySnapshot()
    @State private var isLoading = true
    @State private var isDownloadingTranslation = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("Permissions") {
                row("Microphone", status: permissionLabel(snapshot.microphone))
                #if os(macOS)
                row("System Audio Capture", status: systemAudioLabel(snapshot.systemAudioCapture))
                #else
                if let broadcastMonitor {
                    row(
                        "Screen Broadcast",
                        status: broadcastMonitor.isBroadcastActive
                            ? ("Active", .green) : ("Not running", .secondary))
                }
                #endif
                // A denied permission can only be fixed in the system
                // settings; without a way there the app just looks broken.
                if snapshot.microphone == .denied, let url = privacySettingsURL {
                    Button("Open Privacy Settings…") {
                        openURL(url)
                    }
                }
            }
            Section("Models") {
                row(
                    "Transcription (\(languagePair.transcriptionLocale.identifier))",
                    status: transcriptionLabel(snapshot.transcription)
                )
                if let target = languagePair.translationTarget {
                    row(
                        "Translation (\(languagePair.translationSource.minimalIdentifier) → \(target.minimalIdentifier))",
                        status: translationLabel(snapshot.translation)
                    )
                    if snapshot.translation == .supported {
                        Button("Download Translation Models…") {
                            isDownloadingTranslation = true
                        }
                        .disabled(isDownloadingTranslation)
                    }
                } else {
                    row("Translation", status: ("Off", .secondary))
                }
                row(
                    "Apple Intelligence",
                    status: appleIntelligenceLabel(snapshot.appleIntelligence)
                )
            }
            Section {
                // Statuses can change outside the app (System Settings, model
                // downloads); give the user a way to re-check on demand.
                Button("Refresh") {
                    Task { await refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .background {
            if isDownloadingTranslation, let target = languagePair.translationTarget {
                TranslationDownloadBridge(
                    source: languagePair.translationSource,
                    target: target
                ) { _ in
                    isDownloadingTranslation = false
                    Task { await refresh() }
                }
            }
        }
        .task(id: languagePair) {
            // Re-check whenever the selected language pair changes; a bare
            // `.task` runs once and would keep showing the previous pair's
            // model status.
            isDownloadingTranslation = false
            await refresh()
        }
        .onChange(of: scenePhase) {
            // The user may have just granted a permission in System Settings.
            if scenePhase == .active {
                Task { await refresh() }
            }
        }
    }

    private var privacySettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #endif
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        var next = CapabilitySnapshot()
        next.microphone = capabilities.microphonePermission()
        next.systemAudioCapture = capabilities.systemAudioCaptureStatus()
        next.transcription = await capabilities.transcriptionAvailability(
            for: languagePair.transcriptionLocale)
        if let target = languagePair.translationTarget {
            next.translation = await capabilities.translationAvailability(
                from: languagePair.translationSource, to: target)
        }
        next.appleIntelligence = await capabilities.appleIntelligenceAvailability(
            for: languagePair.transcriptionLocale)
        snapshot = next
    }

    private func row(_ title: LocalizedStringKey, status: (LocalizedStringKey, Color)) -> some View {
        LabeledContent(title) {
            Text(status.0)
                .foregroundStyle(status.1)
        }
    }

    private func permissionLabel(_ state: PermissionState) -> (LocalizedStringKey, Color) {
        switch state {
        case .granted: ("Granted", .green)
        case .denied: ("Denied", .red)
        case .notDetermined: ("Not determined", .secondary)
        }
    }

    private func systemAudioLabel(
        _ status: SystemAudioCaptureStatus
    ) -> (LocalizedStringKey, Color) {
        // Deliberately non-permission wording: the underlying TCC cannot be
        // queried, only the outcome of the last capture attempt is known.
        switch status {
        case .notAttempted: ("Not yet attempted — starts on first use", .secondary)
        case .working: ("Working", .green)
        case .failed: ("Last capture failed", .red)
        }
    }

    private func transcriptionLabel(_ state: TranscriptionAvailability) -> (LocalizedStringKey, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .supported: ("Download required", .orange)
        case .unsupportedLocale: ("Locale unsupported", .red)
        case .unavailableOnDevice: ("Unavailable", .red)
        }
    }

    private func translationLabel(_ state: TranslationAvailability) -> (LocalizedStringKey, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .supported: ("Download required", .orange)
        case .unsupported: ("Pair unsupported", .red)
        }
    }

    private func appleIntelligenceLabel(
        _ state: AppleIntelligenceAvailability
    ) -> (LocalizedStringKey, Color) {
        switch state {
        case .available: ("Ready", .green)
        case .notEnabled: ("Enable Apple Intelligence in System Settings", .orange)
        case .modelNotReady: ("Model downloading…", .orange)
        case .unsupportedLanguage: ("Language not supported", .orange)
        case .deviceNotEligible: ("Not supported on this device", .red)
        }
    }
}
