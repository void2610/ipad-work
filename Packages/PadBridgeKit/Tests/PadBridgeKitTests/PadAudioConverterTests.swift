import AVFAudio
@testable import PadBridgeKit
import Testing

struct PadAudioConverterTests {
    private func sine(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, amplitude: Float, startFrame: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< frames {
                buffer.floatChannelData![channel][frame] = amplitude * sin(2 * .pi * 440 * Float(startFrame + frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    /// 送る形と同じ 48kHz・モノラルなら、長さも大きさも変えない。
    @Test func keepsSameFormat() throws {
        let converter = try #require(PadAudioConverter(from: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!))
        let (data, peak) = try #require(converter.convert(sine(sampleRate: 48_000, channels: 1, frames: 1024, amplitude: 0.5)))
        #expect(data.count == 1024 * 2)
        #expect(abs(peak - 0.5) < 0.01)
    }

    /// Mac のマイクによくある 44.1kHz・ステレオも、48kHz・モノラルの長さにして、声の大きさを保つ。
    @Test func resamplesAndDownmixes() throws {
        let converter = try #require(PadAudioConverter(from: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!))
        var frames = 0
        var peak: Float = 0
        for index in 0 ..< 20 {
            guard let (data, bufferPeak) = converter.convert(sine(sampleRate: 44_100, channels: 2, frames: 4410, amplitude: 0.5, startFrame: index * 4410)) else { continue }
            frames += data.count / 2
            peak = max(peak, bufferPeak)
        }
        // 2 秒分。変換の始めの遅れの分だけ短くなってよい
        #expect((95_000 ... 96_000).contains(frames))
        #expect((0.4 ... 1).contains(peak))
    }

    @Test func rejectsFormatWithoutSampleRate() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)
        #expect(format.flatMap(PadAudioConverter.init(from:)) == nil)
    }
}
