#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// Drives a Picture in Picture window that shows live captions on iOS.
///
/// iOS has no cross-app floating window like macOS's `NSPanel`, but PiP lets a
/// custom `AVSampleBufferDisplayLayer` float over other apps and the lock
/// screen. Caption text (original + translation) is rendered to a pixel buffer
/// and enqueued whenever the transcript changes; with `UIBackgroundModes`
/// `audio` and the microphone session active, this keeps updating while Luma is
/// backgrounded.
@MainActor
final class CaptionPiPController: NSObject {
    /// The layer PiP sources frames from. Mounted (tiny/hidden) by `ContentView`
    /// via `CaptionPiPLayerView`; PiP reads the enqueued buffers, not its size.
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called when PiP actually starts/stops (including user-initiated stop), so
    /// the owning controller can mirror visibility.
    var onActiveChange: ((Bool) -> Void)?

    private var pipController: AVPictureInPictureController?
    private weak var store: SessionStore?
    private var isActive = false

    private let renderSize = CGSize(width: 480, height: 135)
    private let ciContext = CIContext()

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pipController = controller
    }

    func bind(store: SessionStore) {
        self.store = store
    }

    func start() {
        guard let pipController, !isActive else { return }
        isActive = true
        renderLoop()  // enqueue an initial frame and start observing changes
        pipController.startPictureInPicture()
    }

    func stop() {
        isActive = false
        pipController?.stopPictureInPicture()
    }

    // MARK: - Caption rendering

    /// Renders the current caption, then re-registers for the next change.
    private func renderLoop() {
        guard isActive else { return }
        let caption = withObservationTracking {
            currentCaption()
        } onChange: {
            Task { @MainActor [weak self] in self?.renderLoop() }
        }
        enqueue(original: caption.original, translation: caption.translation)
    }

    /// Mirrors `SubtitleOverlayView`: prefer the in-progress (volatile) line,
    /// else the last finalized line and its translation.
    private func currentCaption() -> (original: String, translation: String) {
        guard let store else { return ("", "") }
        let original: String
        if let volatile = store.volatileText {
            original = String(volatile.characters)
        } else {
            original = store.entries.last?.segment.plainText ?? ""
        }
        let translation: String
        if store.volatileText != nil, let volatileTranslation = store.volatileTranslation {
            translation = volatileTranslation
        } else if case .translated(let finalized) = store.entries.last?.translation {
            translation = finalized
        } else {
            translation = ""
        }
        return (original, translation)
    }

    private func enqueue(original: String, translation: String) {
        // Honor the shared overlay settings (the same ones the macOS NSPanel
        // uses) so the Settings → Overlay controls also affect the PiP window.
        let shownOriginal = settingShowOriginal ? original : ""
        let shownTranslation = settingShowTranslation ? translation : ""
        guard let pixelBuffer = makePixelBuffer(size: renderSize),
            let image = captionImage(
                original: shownOriginal, translation: shownTranslation,
                fontSize: settingFontSize, size: renderSize)
        else { return }
        ciContext.render(image, to: pixelBuffer)
        guard let sampleBuffer = makeSampleBuffer(imageBuffer: pixelBuffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }

    private func captionImage(
        original: String, translation: String, fontSize: CGFloat, size: CGSize
    ) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let inset = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            UIColor(white: 0.12, alpha: 1).setFill()
            UIBezierPath(roundedRect: inset, cornerRadius: 18).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingHead

            // Clamp to the small PiP canvas so 1–2 lines stay legible.
            let originalFont = UIFont.systemFont(
                ofSize: min(max(fontSize, 16), 40), weight: .semibold)
            let translationFont = UIFont.systemFont(
                ofSize: min(max(fontSize * 0.86, 14), 34), weight: .regular)
            let textWidth = inset.width - 28

            let placeholder = original.isEmpty && translation.isEmpty
            let originalText = placeholder ? String(localized: "Listening…") : original

            var blocks: [(text: NSAttributedString, height: CGFloat)] = []
            func addBlock(_ string: String, font: UIFont, color: UIColor) {
                guard !string.isEmpty else { return }
                let attributed = NSAttributedString(
                    string: string,
                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
                let measured = attributed.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).height
                blocks.append((attributed, min(measured, font.lineHeight * 2 + 2)))
            }
            addBlock(
                originalText, font: originalFont,
                color: placeholder ? UIColor.white.withAlphaComponent(0.55) : .white)
            addBlock(
                translation, font: translationFont,
                color: UIColor.white.withAlphaComponent(0.92))

            let spacing: CGFloat = 6
            let totalHeight =
                blocks.reduce(0) { $0 + $1.height } + CGFloat(max(0, blocks.count - 1)) * spacing
            var y = inset.midY - totalHeight / 2
            for block in blocks {
                block.text.draw(
                    with: CGRect(x: inset.minX + 14, y: y, width: textWidth, height: block.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += block.height + spacing
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Overlay settings (shared with the macOS NSPanel via UserDefaults)

    private var settingShowOriginal: Bool { defaultsBool(OverlaySettingsKey.showOriginal) }
    private var settingShowTranslation: Bool { defaultsBool(OverlaySettingsKey.showTranslation) }
    private var settingFontSize: CGFloat {
        let stored = UserDefaults.standard.object(forKey: OverlaySettingsKey.fontSize) as? Double
        return CGFloat(stored ?? OverlaySettingsKey.defaultFontSize)
    }

    /// Overlay toggles default to on when unset.
    private func defaultsBool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    // MARK: - Pixel buffer / sample buffer plumbing

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    private func makeSampleBuffer(imageBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription
        else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now, decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
                formatDescription: formatDescription, sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }

        // Live caption: render the newest frame as soon as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first
        {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

// MARK: - PiP delegates

extension CaptionPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Live, indefinite content.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

extension CaptionPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = false
        onActiveChange?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isActive = false
        onActiveChange?(false)
    }
}

/// Mounts the caption display layer in the SwiftUI hierarchy so PiP can source
/// from it. Kept tiny/non-interactive; PiP reads the enqueued sample buffers,
/// not the on-screen size.
struct CaptionPiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.isUserInteractionEnabled = false
        view.hostedLayer = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.setNeedsLayout()
    }

    final class LayerHostView: UIView {
        weak var hostedLayer: CALayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
#endif
