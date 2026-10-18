import Foundation
@testable import PadBridgeKit
import Testing

struct PadAudioTests {
    private func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { PadAudio.encode($0) }
    }

    private func read(_ buffer: inout PCMJitterBuffer, count: Int) -> [Float] {
        var output = [Float](repeating: -9, count: count)
        output.withUnsafeMutableBufferPointer { buffer.read(into: $0) }
        return output
    }

    @Test func encodesAsLittleEndianInt16AndClamps() {
        let data = encode([0, 1, -1, 2])
        let values = data.withUnsafeBytes { raw in (0 ..< 4).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
        #expect(values == [0, Int16.max, -Int16.max, Int16.max])
    }

    /// -50dB 以下は 0、-10dB 以上は 1、その間はまっすぐ割り当てること。
    @Test(arguments: [(Float(0), Float(0)), (0.00316, 0), (0.0316, 0.5), (0.316, 1), (1, 1)])
    func levelMapsDecibelsToZeroOne(peak: Float, expected: Float) {
        #expect(abs(PadAudio.level(peak: peak) - expected) < 0.01)
    }

    @Test func audioRoundTripsOnTheWire() throws {
        let message = WireMessage.audio(encode([0.5, -0.25]))
        let encoded = try message.encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == message)
    }

    /// たまるまでは無音を出し、たまったら届いた順に出す。
    @Test func waitsForThresholdThenPlaysInOrder() {
        var buffer = PCMJitterBuffer(capacity: 100, startThreshold: 4)
        buffer.write(encode([0.5, 0.5]))
        #expect(read(&buffer, count: 2) == [0, 0])
        buffer.write(encode([0.5, -0.5]))
        let played = read(&buffer, count: 5)
        #expect(played.prefix(4).map { ($0 * 100).rounded() } == [50, 50, 50, -50])
        #expect(played[4] == 0)
    }

    /// 止めたときにたまりきっていなければ、残りをそのまま鳴らす (iPad を裏に回した直後に止めたときなど)。
    @Test func playRemainingStartsBelowThreshold() {
        var buffer = PCMJitterBuffer(capacity: 100, startThreshold: 4)
        buffer.write(encode([0.5, -0.5]))
        #expect(read(&buffer, count: 2) == [0, 0])
        buffer.playRemaining()
        #expect(read(&buffer, count: 3).map { ($0 * 100).rounded() } == [50, -50, 0])
        #expect(buffer.consumed == 2)
    }

    /// 途切れたら、またたまるまで待つ。
    @Test func underrunWaitsForThresholdAgain() {
        var buffer = PCMJitterBuffer(capacity: 100, startThreshold: 2)
        buffer.write(encode([0.5, 0.5]))
        _ = read(&buffer, count: 3)
        buffer.write(encode([0.5]))
        #expect(read(&buffer, count: 1) == [0])
    }

    /// 書き込んだ数と、鳴らしたか捨てた数を数え、どこまで鳴らし終えたかを見分けられる。
    @Test func countsWrittenAndConsumedSamples() {
        var buffer = PCMJitterBuffer(capacity: 3, startThreshold: 1)
        buffer.write(encode([0.1, 0.2, 0.3, 0.4]))
        #expect(buffer.written == 4)
        #expect(buffer.consumed == 1)
        _ = read(&buffer, count: 2)
        #expect(buffer.consumed == 3)
        _ = read(&buffer, count: 1)
        #expect(buffer.consumed == buffer.written)
        buffer.removeAll()
        #expect(buffer.written == 0 && buffer.consumed == 0)
    }

    /// 鳴らしている途中で足りなくなったときだけ、途切れたと数える。たまるのを待っている間は数えない。
    @Test func countsUnderrunsOnlyWhilePlaying() {
        var buffer = PCMJitterBuffer(capacity: 100, startThreshold: 2)
        buffer.write(encode([0.5]))
        _ = read(&buffer, count: 4)
        #expect(buffer.underruns == 0)
        buffer.write(encode([0.5, 0.5]))
        _ = read(&buffer, count: 4)
        #expect(buffer.underruns == 1)
        _ = read(&buffer, count: 4)
        #expect(buffer.underruns == 1)
    }

    /// 浮動小数の音もそのまま書き込め、範囲外は切り詰める。
    @Test func writesFloatSamples() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 1)
        [Float(0.5), -0.25, 2].withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, count: 3).map { ($0 * 100).rounded() } == [50, -25, 100])
    }

    /// あふれたら古い音から捨て、遅れがたまらないようにする。
    @Test func overflowDropsOldestSamples() {
        var buffer = PCMJitterBuffer(capacity: 3, startThreshold: 1)
        buffer.write(encode([0.1, 0.2, 0.3, 0.4]))
        #expect(buffer.count == 3)
        #expect(read(&buffer, count: 3).map { ($0 * 10).rounded() } == [2, 3, 4])
    }
}
