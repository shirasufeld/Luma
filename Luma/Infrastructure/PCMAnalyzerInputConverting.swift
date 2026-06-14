import AVFAudio
import Speech

/// Converts captured PCM chunks into `AnalyzerInput` values in the analyzer's
/// preferred format. Internal to the Infrastructure layer.
///
/// Buffer start times are intentionally dropped so the analyzer builds a
/// contiguous, session-relative timeline (pauses don't leave gaps in
/// subtitle timecodes).
nonisolated protocol PCMAnalyzerInputConverting {
    func makeInputs(from chunk: AudioChunk) throws -> [AnalyzerInput]
}

/// macOS 27 / iOS 27 path: the official Speech converter.
@available(macOS 27.0, iOS 27.0, *)
nonisolated final class ModernAnalyzerInputConverter: PCMAnalyzerInputConverting {
    private let converter: AnalyzerInputConverter

    init(analyzerFormat: AVAudioFormat) {
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
    }

    func makeInputs(from chunk: AudioChunk) throws -> [AnalyzerInput] {
        try converter.convert(chunk.buffer, at: nil)
    }
}

/// macOS 26 fallback: manual conversion with `AVAudioConverter`.
nonisolated final class LegacyAnalyzerInputConverter: PCMAnalyzerInputConverting {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func makeInputs(from chunk: AudioChunk) throws -> [AnalyzerInput] {
        let buffer = chunk.buffer
        if buffer.format == targetFormat {
            return [AnalyzerInput(buffer: buffer)]
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            let new = AVAudioConverter(from: buffer.format, to: targetFormat)
            // Avoid priming so output timing lines up with input timing.
            new?.primeMethod = .none
            converter = new
        }
        guard let converter else {
            throw TranscriptionError.noCompatibleAudioFormat
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? TranscriptionError.noCompatibleAudioFormat
        }
        guard output.frameLength > 0 else { return [] }
        return [AnalyzerInput(buffer: output)]
    }
}
