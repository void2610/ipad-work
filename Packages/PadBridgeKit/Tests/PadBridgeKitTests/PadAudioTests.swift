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

    /// 途切れたら、またたまるまで待つ。
    @Test func underrunWaitsForThresholdAgain() {
        var buffer = PCMJitterBuffer(capacity: 100, startThreshold: 2)
        buffer.write(encode([0.5, 0.5]))
        _ = read(&buffer, count: 3)
        buffer.write(encode([0.5]))
        #expect(read(&buffer, count: 1) == [0])
    }

    /// あふれたら古い音から捨て、遅れがたまらないようにする。
    @Test func overflowDropsOldestSamples() {
        var buffer = PCMJitterBuffer(capacity: 3, startThreshold: 1)
        buffer.write(encode([0.1, 0.2, 0.3, 0.4]))
        #expect(buffer.count == 3)
        #expect(read(&buffer, count: 3).map { ($0 * 10).rounded() } == [2, 3, 4])
    }
}
