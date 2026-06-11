import AVFoundation
import Foundation
import Speech
import Translation

/// Production implementation of `CapabilityChecking` backed by AVFoundation,
/// Speech (SpeechTranscriber), and Translation.
nonisolated final class CapabilityService: CapabilityChecking {

    func microphonePermission() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    func requestMicrophonePermission() async -> PermissionState {
        await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
    }

    func transcriptionAvailability(for locale: Locale) async -> TranscriptionAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailableOnDevice
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupportedLocale
        }
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains {
            $0.identifier(.bcp47) == supported.identifier(.bcp47)
        }
        return isInstalled ? .installed(supported) : .supported(supported)
    }

    func supportedTranscriptionLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    // `LanguageAvailability` is not Sendable, so these run entirely on the
    // concurrent executor (`@concurrent`) and never let the instance cross
    // an isolation boundary.
    @concurrent
    func translationAvailability(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> TranslationAvailability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    @concurrent
    func supportedTranslationLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
}
