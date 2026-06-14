// ScreenCaptureKit ships only in the iOS device SDK, not the simulator SDK,
// so system-audio capture is device-only. The simulator falls back to the
// microphone (see AppDependencies).
#if os(iOS) && !targetEnvironment(simulator)
import AVFAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// iOS system-audio capture via ScreenCaptureKit, available on iOS 27+
/// (`SCStreamConfiguration.capturesAudio`, `SCStreamOutputType.audio`).
///
/// Flow: present `SCContentSharingPicker` for the current application → receive
/// an `SCContentFilter` from the picker observer → start an `SCStream` whose
/// audio sample buffers are converted to domain `AudioChunk`s.
///
/// Unlike macOS — where a Core Audio process tap captures other apps' output
/// silently after a one-time TCC prompt — iOS requires the user to grant
/// capture through the system picker each session.
///
/// VERIFICATION STATUS: every API call here is verified against the iOS 27
/// SDK on disk and the file compiles for an iOS 27 device. Runtime behavior
/// has NOT been verified on an iOS 27 device (none was available), and the
/// effective capture scope (current app vs. system-wide, which may require a
/// Broadcast Upload Extension) still needs on-device confirmation. See
/// docs/research.md.
///
/// `SCContentFilter` and `SCStream` are not `Sendable`, so — following the same
/// confinement pattern as `AppleTranslationProvider` — all ScreenCaptureKit
/// objects live inside a nonisolated `CaptureEngine`; the actor only forwards
/// `Sendable` values (`AsyncStream<AudioChunk>`, `Void`, errors) across its
/// isolation boundary.
@available(iOS 27.0, *)
actor SCStreamSystemAudioProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .systemAudio

    private let engine = CaptureEngine()

    enum CaptureError: Error {
        case pickerUnavailable
        case pickerCancelled
        case pickerFailed(any Error)
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        try await engine.start()
    }

    func pause() async {
        await engine.pause()
    }

    func resume() async throws {
        try await engine.resume()
    }

    func stop() async {
        await engine.stop()
    }
}

/// Owns every (non-Sendable) ScreenCaptureKit object. The owning actor
/// serializes calls, so the mutable state here is never accessed concurrently.
@available(iOS 27.0, *)
private nonisolated final class CaptureEngine: @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.example.Luma.scstream.audio")

    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isCapturing = false

    func start() async throws -> AsyncStream<AudioChunk> {
        await teardown()

        let filter = try await PickerCoordinator().presentAndAwaitFilter()

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let (audioStream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation

        let output = AudioStreamOutput(continuation: continuation)
        self.output = output

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        self.stream = stream
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        isCapturing = true

        return audioStream
    }

    func pause() async {
        guard isCapturing, let stream else { return }
        try? await stream.stopCapture()
        isCapturing = false
    }

    func resume() async throws {
        guard !isCapturing, let stream else { return }
        try await stream.startCapture()
        isCapturing = true
    }

    func stop() async {
        await teardown()
        continuation?.finish()
        continuation = nil
    }

    private func teardown() async {
        if let stream, let output {
            if isCapturing {
                try? await stream.stopCapture()
            }
            try? stream.removeStreamOutput(output, type: .audio)
        }
        stream = nil
        output = nil
        isCapturing = false
    }
}

/// Receives `SCStream` audio sample buffers on the sample queue and converts
/// each one to an `AudioChunk`. Also serves as the stream delegate so a capture
/// failure finishes the stream.
///
/// `@unchecked Sendable`: the continuation is Sendable and the converter holds
/// no mutable state; callbacks are delivered serially on the sample queue.
@available(iOS 27.0, *)
private nonisolated final class AudioStreamOutput:
    NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
    private let continuation: AsyncStream<AudioChunk>.Continuation

    init(continuation: AsyncStream<AudioChunk>.Continuation) {
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
            let formatDescription = sampleBuffer.formatDescription,
            var asbd = formatDescription.audioStreamBasicDescription,
            let format = AVAudioFormat(streamDescription: &asbd)
        else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let sourceFirst = audioBufferList.first else { return }
            let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
            guard bytesPerFrame > 0 else { return }
            let frames = AVAudioFrameCount(sourceFirst.mDataByteSize / bytesPerFrame)
            guard frames > 0,
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return }
            pcm.frameLength = frames

            let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for (index, sourceBuffer) in audioBufferList.enumerated()
            where index < destination.count {
                guard let sourceData = sourceBuffer.mData,
                    let destinationData = destination[index].mData
                else { continue }
                let bytes = min(sourceBuffer.mDataByteSize, destination[index].mDataByteSize)
                memcpy(destinationData, sourceData, Int(bytes))
                destination[index].mDataByteSize = bytes
            }
            continuation.yield(AudioChunk(buffer: pcm))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
    }
}

/// Drives `SCContentSharingPicker` and bridges its observer callbacks to a
/// single `async` result. Presentation happens on the main actor; the
/// resulting `SCContentFilter` is delivered within this nonisolated context so
/// it never crosses an actor boundary.
///
/// `@unchecked Sendable`: the one-shot continuation is guarded by `lock`.
@available(iOS 27.0, *)
private nonisolated final class PickerCoordinator:
    NSObject, SCContentSharingPickerObserver, @unchecked Sendable
{
    /// One-shot ownership transfer of the non-Sendable `SCContentFilter` from
    /// the picker callback into the awaiting task (same rule as `AudioChunk`).
    private struct FilterBox: @unchecked Sendable {
        let filter: SCContentFilter
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<FilterBox, any Error>?
    private var hasResumed = false

    func presentAndAwaitFilter() async throws -> SCContentFilter {
        let box = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            Task { @MainActor in
                let picker = SCContentSharingPicker.shared
                guard picker.isAvailable else {
                    self.fail(SCStreamSystemAudioProvider.CaptureError.pickerUnavailable)
                    return
                }
                // `allowedPickerModes` is macOS-only; iOS presents the current
                // application's content with the default configuration.
                picker.add(self)
                picker.isActive = true
                picker.presentForCurrentApplication()
            }
        }
        return box.filter
    }

    /// Pops the pending continuation exactly once and stops the picker.
    private func takePending() -> CheckedContinuation<FilterBox, any Error>? {
        let pending: CheckedContinuation<FilterBox, any Error>? = lock.withLock {
            guard !hasResumed else { return nil }
            hasResumed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard pending != nil else { return nil }
        Task { @MainActor in
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
        }
        return pending
    }

    private func fail(_ error: any Error) {
        takePending()?.resume(throwing: error)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        takePending()?.resume(returning: FilterBox(filter: filter))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        fail(SCStreamSystemAudioProvider.CaptureError.pickerCancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        fail(SCStreamSystemAudioProvider.CaptureError.pickerFailed(error))
    }
}
#endif
