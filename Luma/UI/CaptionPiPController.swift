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
        guard let pipController else { return }
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
        guard let pixelBuffer = makePixelBuffer(size: renderSize),
            let image = captionImage(original: original, translation: translation, size: renderSize)
        else { return }
        ciContext.render(image, to: pixelBuffer)
        guard let sampleBuffer = makeSampleBuffer(imageBuffer: pixelBuffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }

    private func captionImage(original: String, translation: String, size: CGSize) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let inset = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            let card = UIBezierPath(roundedRect: inset, cornerRadius: 18)
            UIColor(white: 0.12, alpha: 1).setFill()
            card.fill()

            let placeholder = original.isEmpty && translation.isEmpty
            let originalText = placeholder ? String(localized: "Listening…") : original

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingHead

            var y = inset.minY + 14
            let textWidth = inset.width - 28

            if !originalText.isEmpty {
                y = drawText(
                    originalText,
                    font: .systemFont(ofSize: 30, weight: .semibold),
                    color: placeholder ? UIColor.white.withAlphaComponent(0.55) : .white,
                    paragraph: paragraph,
                    in: CGRect(x: inset.minX + 14, y: y, width: textWidth, height: 44))
            }
            if !translation.isEmpty {
                _ = drawText(
                    translation,
                    font: .systemFont(ofSize: 26, weight: .regular),
                    color: UIColor.white.withAlphaComponent(0.92),
                    paragraph: paragraph,
                    in: CGRect(x: inset.minX + 14, y: y + 6, width: textWidth, height: 40))
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Draws (up to two lines of) text and returns the y just below it.
    private func drawText(
        _ text: String, font: UIFont, color: UIColor,
        paragraph: NSParagraphStyle, in rect: CGRect
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
        return rect.maxY
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
