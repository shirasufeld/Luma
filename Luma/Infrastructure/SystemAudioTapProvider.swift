#if os(macOS)
import AVFAudio
import CoreAudio
import Foundation

/// Which output audio to capture.
nonisolated enum SystemAudioScope: Sendable, Equatable {
    /// Mixdown of every process's output.
    case allProcesses
    /// Output of specific apps, identified by bundle ID (macOS 26+
    /// `CATapDescription.bundleIDs`). Experimental on beta systems.
    case bundleIDs([String])
}

nonisolated enum SystemAudioCaptureError: Error {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case tapFormatUnavailable
    case defaultOutputDeviceUnavailable
}

/// Captures system (or per-app) output audio with a Core Audio process tap
/// fed through a private aggregate device, following Apple's "Capturing
/// system audio with Core Audio taps" flow:
/// tap -> aggregate device (tap list, auto-start) -> IO proc -> AsyncStream.
///
/// Requires the `NSAudioCaptureUsageDescription` Info.plist key; macOS
/// prompts for "System Audio Recording" on first capture. No Screen
/// Recording permission is involved.
actor SystemAudioTapProvider: AudioInputProviding {
    nonisolated let kind: AudioInputKind = .systemAudio

    private let scope: SystemAudioScope

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isCapturing = false

    init(scope: SystemAudioScope = .allProcesses) {
        self.scope = scope
    }

    func start() throws -> AsyncStream<AudioChunk> {
        teardown()

        // 1. Create the process tap.
        let description = makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.tapCreationFailed(status)
        }
        tapID = newTapID

        do {
            // 2. The tap's stream format defines what the IO proc receives.
            guard var tapFormat = try? readTapStreamFormat(tapID: tapID),
                let format = AVAudioFormat(streamDescription: &tapFormat)
            else {
                throw SystemAudioCaptureError.tapFormatUnavailable
            }

            // 3. Wrap the tap in a private aggregate device anchored to the
            //    default output device's clock.
            let tapUID = try readObjectUID(
                objectID: tapID, selector: kAudioTapPropertyUID)
            let outputUID = try defaultOutputDeviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Luma System Audio Capture",
                kAudioAggregateDeviceUIDKey: "com.example.Luma.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr, newAggregateID != kAudioObjectUnknown else {
                throw SystemAudioCaptureError.aggregateCreationFailed(status)
            }
            aggregateID = newAggregateID

            // 4. IO proc copies each input buffer list into an AudioChunk.
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioChunk.self, bufferingPolicy: .unbounded)
            self.continuation = continuation
            let handler = TapIOHandler(format: format, continuation: continuation)

            var newProcID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) {
                _, inInputData, _, _, _ in
                handler.handle(bufferList: inInputData)
            }
            guard status == noErr, let procID = newProcID else {
                throw SystemAudioCaptureError.ioProcCreationFailed(status)
            }
            ioProcID = procID

            // 5. Start. The first start triggers the system-audio TCC prompt.
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else {
                throw SystemAudioCaptureError.deviceStartFailed(status)
            }
            isCapturing = true
            return stream
        } catch {
            teardown()
            throw error
        }
    }

    func pause() {
        guard isCapturing, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isCapturing = false
    }

    func resume() throws {
        guard !isCapturing, let ioProcID, aggregateID != kAudioObjectUnknown else { return }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw SystemAudioCaptureError.deviceStartFailed(status)
        }
        isCapturing = true
    }

    func stop() {
        teardown()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Setup helpers

    private func makeTapDescription() -> CATapDescription {
        let description: CATapDescription
        switch scope {
        case .allProcesses:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .bundleIDs(let bundleIDs):
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = bundleIDs
        }
        description.name = "Luma Tap"
        // Private: invisible to other processes. Unmuted: the user keeps
        // hearing the audio that Luma captions.
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            if isCapturing {
                AudioDeviceStop(aggregateID, ioProcID)
            }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isCapturing = false
    }

    // MARK: - Core Audio property plumbing

    private func readTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw SystemAudioCaptureError.tapFormatUnavailable
        }
        return format
    }

    private func readObjectUID(
        objectID: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw SystemAudioCaptureError.tapFormatUnavailable
        }
        return uid as String
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.defaultOutputDeviceUnavailable
        }
        return try readObjectUID(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }
}

/// Runs on the HAL's realtime IO thread: copies each incoming buffer list
/// into a fresh `AVAudioPCMBuffer` and yields it.
///
/// `@unchecked Sendable`: `format` is immutable after init and the
/// continuation is itself Sendable; `handle` is only invoked serially by the
/// HAL for one IO proc.
private nonisolated final class TapIOHandler: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AudioChunk>.Continuation

    init(format: AVAudioFormat, continuation: AsyncStream<AudioChunk>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    func handle(bufferList: UnsafePointer<AudioBufferList>) {
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuffer = source.first else { return }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(firstBuffer.mDataByteSize / bytesPerFrame)
        guard frames > 0,
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        pcm.frameLength = frames

        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (index, sourceBuffer) in source.enumerated() where index < destination.count {
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
#endif
