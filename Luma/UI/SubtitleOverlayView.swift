#if os(macOS)
import SwiftUI

/// Content of the macOS floating caption window (the `NSPanel` overlay): the
/// most recent finalized line, its translation, and the running volatile
/// hypothesis. iOS renders captions into a Picture in Picture window instead
/// (see `CaptionPiPController`).
///
/// Honors Reduce Transparency (falls back to a solid surface), supports
/// VoiceOver via a live accessibility label, and keeps decoration minimal
/// for long-running, low-distraction use.
struct SubtitleOverlayView: View {
    var store: SessionStore

    @AppStorage(OverlaySettingsKey.fontSize)
    private var fontSize: Double = OverlaySettingsKey.defaultFontSize
    @AppStorage(OverlaySettingsKey.surface)
    private var surfaceRawValue: String = OverlaySurfaceStyle.liquidGlass.rawValue
    @AppStorage(OverlaySettingsKey.showOriginal)
    private var showOriginal = true
    @AppStorage(OverlaySettingsKey.showTranslation)
    private var showTranslation = true

    @AppStorage(AppLanguage.defaultsKey)
    private var appLanguageRaw = AppLanguage.system.rawValue

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        captionStack
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(surface)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.updatesFrequently)
            .appLanguage(appLanguageRaw)
    }

    // MARK: - Caption content

    private var captionStack: some View {
        VStack(spacing: 6) {
            if showOriginal {
                Text(primaryLine)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
            }
            if showTranslation, !translationLine.isEmpty {
                Text(translationLine)
                    .font(.system(size: fontSize * 0.9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
            }
            if primaryLine.isEmpty && translationLine.isEmpty {
                Text(idleText)
                    .font(.system(size: max(fontSize * 0.6, 13)))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryLine: String {
        if let volatileText = store.volatileText {
            return String(volatileText.characters)
        }
        return store.entries.last?.segment.plainText ?? ""
    }

    private var translationLine: String {
        // Fast mode live-translates the in-progress line; prefer that while
        // a volatile hypothesis is showing.
        if store.volatileText != nil, let volatileTranslation = store.volatileTranslation {
            return volatileTranslation
        }
        guard case .translated(let translation) = store.entries.last?.translation else {
            return ""
        }
        return translation
    }

    private var idleText: LocalizedStringKey {
        switch store.sessionState {
        case .idle: "Captions paused"
        case .preparing: "Preparing…"
        default: "Listening…"
        }
    }

    private var accessibilityText: String {
        let original = primaryLine
        let translation = translationLine
        if translation.isEmpty { return original }
        return "\(original). \(translation)"
    }

    // MARK: - Surface

    private var surfaceStyle: OverlaySurfaceStyle {
        // Reduce Transparency always wins over the user's surface choice.
        if reduceTransparency { return .solid }
        return OverlaySurfaceStyle(rawValue: surfaceRawValue) ?? .liquidGlass
    }

    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        switch surfaceStyle {
        case .liquidGlass:
            Color.clear
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
        case .material:
            shape.fill(.ultraThinMaterial)
        case .solid:
            shape.fill(.black.opacity(0.82))
        }
    }
}
#endif
