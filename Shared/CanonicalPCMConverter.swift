import AVFAudio
import CoreMedia

/// Why a ReplayKit sample buffer was dropped instead of forwarded.
///
/// Each case names the exact stage that failed so a single log line from the
/// extension is enough to localize a silent-audio report.
nonisolated enum PCMDropReason: Error, CustomStringConvertible {
    case noFormatDescription
    case emptySampleBuffer
    case unsupportedSourceFormat(AudioStreamBasicDescription)
    case converterUnavailable
    case bufferListCopyFailed(OSStatus)
    case conversionFailed(String)

    var description: String {
        switch self {
        case .noFormatDescription: "noFormatDescription"
        case .emptySampleBuffer: "emptySampleBuffer"
        case .unsupportedSourceFormat(let asbd):
            "unsupportedSourceFormat(id=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) "
                + "rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel))"
        case .converterUnavailable: "converterUnavailable"
        case .bufferListCopyFailed(let status): "bufferListCopyFailed(\(status))"
        case .conversionFailed(let message): "conversionFailed(\(message))"
        }
    }
}

/// Converts arbitrary ReplayKit audio sample buffers to the canonical
/// interleaved mono Float32 PCM that crosses the App Group ring.
///
/// ReplayKit's `.audioApp` buffers vary by source app: interleaved or
/// non-interleaved, mono or stereo, Float32 or Int16 — and 16-bit content is
/// frequently **big-endian**, which `AVAudioFormat(streamDescription:)` cannot
/// represent. This class normalizes all of them; every failure is a typed
/// `PCMDropReason` so the caller can log instead of silently dropping.
///
/// Not thread-safe: the caller (the extension's sample handler) serializes
/// access under its own lock.
nonisolated final class CanonicalPCMConverter {
    private let canonicalFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    /// Called when the incoming stream's format first appears or changes —
    /// hook for one-shot diagnostics logging.
    var onSourceFormatChange: ((AudioStreamBasicDescription) -> Void)?

    init(canonicalFormat: AVAudioFormat) {
        self.canonicalFormat = canonicalFormat
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> Result<AVAudioPCMBuffer, PCMDropReason> {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return .failure(.noFormatDescription) }
        var asbd = asbdPointer.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return .failure(.emptySampleBuffer) }
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return .failure(.unsupportedSourceFormat(asbd))
        }

        // AVAudioFormat cannot represent big-endian PCM; describe the buffer as
        // native-endian and byte-swap the extracted samples below.
        let needsByteSwap =
            asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 && asbd.mBitsPerChannel == 16
        if needsByteSwap {
            asbd.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        }
        guard let source = AVAudioFormat(streamDescription: &asbd) else {
            return .failure(.unsupportedSourceFormat(asbd))
        }

        if converter == nil || !(sourceFormat?.isEqual(source) ?? false) {
            converter = AVAudioConverter(from: source, to: canonicalFormat)
            sourceFormat = source
            onSourceFormatChange?(asbd)
        }
        guard let converter else { return .failure(.converterUnavailable) }

        let sourceBuffer: AVAudioPCMBuffer
        switch extract(sampleBuffer, format: source, frameCount: frameCount) {
        case .success(let extracted): sourceBuffer = extracted
        case .failure(let reason): return .failure(reason)
        }
        if needsByteSwap {
            byteSwap16(sourceBuffer)
        }

        let ratio = canonicalFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity)
        else { return .failure(.conversionFailed("output allocation failed")) }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error else {
            return .failure(.conversionFailed(conversionError?.localizedDescription ?? "unknown"))
        }
        // `frameLength == 0` is a valid outcome: the converter buffered the
        // input internally and will emit it with a later call. Not a drop.
        return .success(output)
    }

    /// Copies the sample buffer's audio into an `AVAudioPCMBuffer` of the same
    /// format. `withAudioBufferList` presents the data in the buffer's own
    /// layout (one buffer when interleaved, one per channel otherwise), and the
    /// PCM buffer's ABL has the matching shape by construction, so a per-buffer
    /// clamped copy handles every layout.
    private func extract(
        _ sampleBuffer: CMSampleBuffer, format: AVAudioFormat, frameCount: CMItemCount
    ) -> Result<AVAudioPCMBuffer, PCMDropReason> {
        guard
            let pcm = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return .failure(.bufferListCopyFailed(-1)) }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        do {
            try sampleBuffer.withAudioBufferList(blockBufferMemoryAllocator: kCFAllocatorDefault) {
                sourceList, _ in
                let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                for (index, sourceBuffer) in sourceList.enumerated()
                where index < destination.count {
                    guard let sourceData = sourceBuffer.mData,
                        let destinationData = destination[index].mData
                    else { continue }
                    let bytes = min(sourceBuffer.mDataByteSize, destination[index].mDataByteSize)
                    memcpy(destinationData, sourceData, Int(bytes))
                }
            }
        } catch {
            return .failure(.bufferListCopyFailed(OSStatus((error as NSError).code)))
        }
        return .success(pcm)
    }

    private func byteSwap16(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<UInt16>.size
            let samples = data.bindMemory(to: UInt16.self, capacity: count)
            for index in 0..<count {
                samples[index] = samples[index].byteSwapped
            }
        }
    }
}
