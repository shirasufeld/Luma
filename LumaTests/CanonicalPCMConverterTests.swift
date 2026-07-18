import AVFAudio
import CoreMedia
import Foundation
import Testing

@testable import Luma

/// Exercises the broadcast extension's PCM canonicalization against the source
/// layouts ReplayKit actually delivers: interleaved/non-interleaved,
/// mono/stereo, Float32/Int16, and big-endian Int16.
struct CanonicalPCMConverterTests {

    private let canonical = BroadcastAudio.makeCanonicalFormat()

    @Test func interleavedFloat32MonoPassesThrough() throws {
        // The converter may hold a tail of each call in its internal buffer,
        // so conservation is asserted cumulatively over several calls.
        let converter = CanonicalPCMConverter(canonicalFormat: canonical)
        let buffer = try makeSampleBuffer(
            sampleRate: 48_000, channels: 1, isFloat: true, interleaved: true, frames: 4800)
        let result = try accumulate(converter, buffer: buffer, times: 5)
        #expect(result.formatOK)
        #expect(result.frames > 4 * 4800 && result.frames <= 5 * 4800 + 64)
        #expect(abs(result.rms - sineRMS) < 0.05)
    }

    @Test func interleavedInt16StereoIsConverted() throws {
        let converter = CanonicalPCMConverter(canonicalFormat: canonical)
        let buffer = try makeSampleBuffer(
            sampleRate: 44_100, channels: 2, isFloat: false, interleaved: true, frames: 4410)
        let result = try accumulate(converter, buffer: buffer, times: 5)
        #expect(result.formatOK)
        #expect(result.frames > 4 * 4800 && result.frames <= 5 * 4800 + 128)
        #expect(abs(result.rms - sineRMS) < 0.05)
    }

    @Test func bigEndianInt16MatchesLittleEndian() throws {
        // Identical audio delivered big- and little-endian must produce the
        // same canonical output — catches a missing or double byte swap.
        let littleConverter = CanonicalPCMConverter(canonicalFormat: canonical)
        let bigConverter = CanonicalPCMConverter(canonicalFormat: canonical)
        let little = try makeSampleBuffer(
            sampleRate: 44_100, channels: 2, isFloat: false, interleaved: true, frames: 4410)
        let big = try makeSampleBuffer(
            sampleRate: 44_100, channels: 2, isFloat: false, interleaved: true, frames: 4410,
            bigEndian: true)
        let littleOut = try #require(littleConverter.convert(little).successValue)
        let bigOut = try #require(bigConverter.convert(big).successValue)
        #expect(littleOut.frameLength == bigOut.frameLength)
        let littleSamples = try #require(littleOut.floatChannelData?[0])
        let bigSamples = try #require(bigOut.floatChannelData?[0])
        var maxDifference: Float = 0
        for index in 0..<Int(littleOut.frameLength) {
            maxDifference = max(maxDifference, abs(littleSamples[index] - bigSamples[index]))
        }
        #expect(maxDifference < 1e-3)
    }

    @Test func nonInterleavedFloat32StereoIsConverted() throws {
        let converter = CanonicalPCMConverter(canonicalFormat: canonical)
        let buffer = try makeSampleBuffer(
            sampleRate: 48_000, channels: 2, isFloat: true, interleaved: false, frames: 4800)
        let result = try accumulate(converter, buffer: buffer, times: 5)
        #expect(result.formatOK)
        #expect(result.frames > 4 * 4800 && result.frames <= 5 * 4800 + 64)
        #expect(abs(result.rms - sineRMS) < 0.05)
    }

    @Test func emptyBufferReportsEmptySampleBuffer() throws {
        let converter = CanonicalPCMConverter(canonicalFormat: canonical)
        let buffer = try makeEmptySampleBuffer()
        switch converter.convert(buffer) {
        case .success: Issue.record("expected failure for an empty sample buffer")
        case .failure(let reason):
            guard case .emptySampleBuffer = reason else {
                Issue.record("expected emptySampleBuffer, got \(reason)")
                return
            }
        }
    }

    @Test func compressedFormatReportsUnsupported() throws {
        let converter = CanonicalPCMConverter(canonicalFormat: canonical)
        let buffer = try makeSampleBuffer(
            sampleRate: 48_000, channels: 1, isFloat: true, interleaved: true, frames: 480,
            formatID: kAudioFormatMPEG4AAC)
        switch converter.convert(buffer) {
        case .success: Issue.record("expected failure for a non-PCM format")
        case .failure(let reason):
            guard case .unsupportedSourceFormat = reason else {
                Issue.record("expected unsupportedSourceFormat, got \(reason)")
                return
            }
        }
    }

    // MARK: - Synthesis helpers

    /// RMS of the 0.5-amplitude sine used by `makeSampleBuffer`.
    private var sineRMS: Float { 0.5 / Float(2.0.squareRoot()) }

    /// Feeds the same sample buffer repeatedly and accumulates the canonical
    /// output — total frames, overall RMS, and output-format conformance.
    private func accumulate(
        _ converter: CanonicalPCMConverter, buffer: CMSampleBuffer, times: Int
    ) throws -> (frames: Int, rms: Float, formatOK: Bool) {
        var samples: [Float] = []
        var formatOK = true
        for _ in 0..<times {
            let output = try #require(converter.convert(buffer).successValue)
            formatOK =
                formatOK && output.format.sampleRate == canonical.sampleRate
                && output.format.channelCount == canonical.channelCount
            if let channel = output.floatChannelData?[0] {
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channel, count: Int(output.frameLength)))
            }
        }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
        return (samples.count, rms, formatOK)
    }

    /// Builds a CMSampleBuffer holding a 440 Hz, 0.5-amplitude sine in the
    /// requested source layout.
    private func makeSampleBuffer(
        sampleRate: Double, channels: UInt32, isFloat: Bool, interleaved: Bool, frames: Int,
        bigEndian: Bool = false, formatID: AudioFormatID = kAudioFormatLinearPCM
    ) throws -> CMSampleBuffer {
        let bitsPerChannel: UInt32 = isFloat ? 32 : 16
        let bytesPerSample = bitsPerChannel / 8
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        flags |= isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        if bigEndian { flags |= kAudioFormatFlagIsBigEndian }
        let bytesPerFrame = interleaved ? channels * bytesPerSample : bytesPerSample
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: bitsPerChannel, mReserved: 0)

        var formatDescription: CMAudioFormatDescription?
        try check(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &formatDescription))
        let format = try #require(formatDescription)

        let data = makeSineData(
            frames: frames, channels: Int(channels), sampleRate: sampleRate, isFloat: isFloat,
            interleaved: interleaved, bigEndian: bigEndian)

        var blockBuffer: CMBlockBuffer?
        try check(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: max(data.count, 1),
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: max(data.count, 1), flags: 0, blockBufferOut: &blockBuffer))
        let block = try #require(blockBuffer)
        if !data.isEmpty {
            try data.withUnsafeBytes { bytes in
                try check(
                    CMBlockBufferReplaceDataBytes(
                        with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                        dataLength: data.count))
            }
        }

        var sampleBuffer: CMSampleBuffer?
        try check(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer))
        return try #require(sampleBuffer)
    }

    /// A sample buffer with a valid PCM format description but zero samples —
    /// `CMAudioSampleBufferCreateReady...` refuses a zero count, so build it
    /// with the low-level constructor.
    private func makeEmptySampleBuffer() throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        try check(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &formatDescription))
        var sampleBuffer: CMSampleBuffer?
        try check(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: try #require(formatDescription), sampleCount: 0,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sampleBuffer))
        return try #require(sampleBuffer)
    }

    private func makeSineData(
        frames: Int, channels: Int, sampleRate: Double, isFloat: Bool, interleaved: Bool,
        bigEndian: Bool
    ) -> Data {
        let samples = (0..<frames).map { frame in
            Float(0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / sampleRate))
        }
        var data = Data()
        if interleaved {
            for sample in samples {
                for _ in 0..<channels {
                    append(sample, to: &data, isFloat: isFloat, bigEndian: bigEndian)
                }
            }
        } else {
            for _ in 0..<channels {
                for sample in samples {
                    append(sample, to: &data, isFloat: isFloat, bigEndian: bigEndian)
                }
            }
        }
        return data
    }

    private func append(_ sample: Float, to data: inout Data, isFloat: Bool, bigEndian: Bool) {
        if isFloat {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        } else {
            let value = Int16(max(-32768, min(32767, sample * 32767)))
            let stored = bigEndian ? value.bigEndian : value.littleEndian
            withUnsafeBytes(of: stored) { data.append(contentsOf: $0) }
        }
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

extension Result {
    fileprivate var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
