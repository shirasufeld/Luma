import AVFAudio
import Foundation
import Testing

@testable import Luma

struct AudioLevelTests {

    private func makeBuffer(_ fill: (Int) -> Float, frames: Int = 4800) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames {
            channel[index] = fill(index)
        }
        return buffer
    }

    @Test func silenceIsZero() {
        let level = AudioLevel.normalizedLevel(of: makeBuffer { _ in 0 })
        #expect(level == 0)
    }

    @Test func fullScaleSineIsNearOne() {
        let buffer = makeBuffer { index in
            sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        let level = AudioLevel.normalizedLevel(of: buffer)
        // Full-scale sine RMS is -3 dB; on the -50…0 dB scale that is 0.94.
        #expect(level != nil && level! > 0.9)
    }

    @Test func quietSignalLandsBetween() {
        let buffer = makeBuffer { index in
            0.01 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        let level = AudioLevel.normalizedLevel(of: buffer)
        // -43 dB RMS → ~0.14 on the normalized scale.
        #expect(level != nil && level! > 0.05 && level! < 0.3)
    }

    @Test func nonFloatBufferIsNil() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        #expect(AudioLevel.normalizedLevel(of: buffer) == nil)
    }
}
