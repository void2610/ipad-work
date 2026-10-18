import Foundation
@testable import PadBridgeKit
import Testing

struct MacAudioOpusTests {
    /// 左だけに 440Hz を入れた 1 秒を、送信単位のチャンクごとにエンコードし、デコードして戻す。
    private func roundTrip() throws -> (packets: [Data], decoded: [Int16]) {
        let encoder = try #require(MacAudioEncoder())
        let decoder = try #require(MacAudioDecoder())
        var packets: [Data] = []
        var decoded: [Int16] = []
        for chunkIndex in 0 ..< 50 {
            let left = (0 ..< MacAudio.chunkFrames).map { Float(sin(2 * Double.pi * 440 * Double(chunkIndex * MacAudio.chunkFrames + $0) / Double(MacAudio.sampleRate)) * 0.5) }
            let right = [Float](repeating: 0, count: MacAudio.chunkFrames)
            let chunk = left.withUnsafeBufferPointer { left in right.withUnsafeBufferPointer { MacAudio.encode(left: left, right: $0) } }
            for packet in encoder.encode(chunk) {
                packets.append(packet)
                let pcm = try #require(decoder.decode(packet))
                decoded += pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            }
        }
        return (packets, decoded)
    }

    private func rms(_ samples: some Collection<Int16>) -> Double {
        sqrt(samples.reduce(0) { $0 + pow(Double($1) / Double(Int16.max), 2) } / Double(samples.count))
    }

    /// チャンク 1 つが 1 パケットになり、デコードすると左右がそのまま聞こえる (左は 0.5 の正弦波の実効値 0.354、右は無音)。
    @Test func roundTripKeepsSoundOnEachChannel() throws {
        let (packets, decoded) = try roundTrip()
        #expect(packets.count == 50)
        // エンコード先頭の遅延 (約 6.5ms) を含む最初の 100ms は比較しない
        let steady = decoded.dropFirst(MacAudio.sampleRate / 10 * MacAudio.channelCount)
        let left = steady.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let right = steady.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        #expect(abs(rms(left) - 0.354) < 0.05, "左の実効値 \(rms(left))")
        #expect(rms(right) < 0.02, "右の実効値 \(rms(right))")
    }

    /// 無圧縮の 1 チャンク 3,840 バイトに対し、128 kbps の Opus は平均 320 バイトほどになる。
    @Test func packetsAreAboutTheTargetBitRate() throws {
        let (packets, _) = try roundTrip()
        let average = packets.map(\.count).reduce(0, +) / packets.count
        #expect(average < 480, "平均 \(average) バイト")
    }
}
