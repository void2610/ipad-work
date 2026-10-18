@preconcurrency import AVFAudio
import Foundation
@testable import PadBridgeKit
import Testing

struct MacAudioTests {
    private func encode(left: [Float], right: [Float]) -> Data {
        left.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in MacAudio.encode(left: left, right: right) }
        }
    }

    private func read(_ buffer: inout PCMJitterBuffer, frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: -9, count: frames)
        var right = [Float](repeating: -9, count: frames)
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in buffer.read(left: left, right: right) }
        }
        return (left.map { ($0 * 100).rounded() }, right.map { ($0 * 100).rounded() })
    }

    @Test func interleavesChannelsAsLittleEndianInt16AndClamps() {
        let data = encode(left: [0, 2], right: [1, -1])
        let values = data.withUnsafeBytes { raw in (0 ..< 4).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
        #expect(values == [0, Int16.max, Int16.max, -Int16.max])
    }

    @Test func detectsSilentChunks() {
        #expect(MacAudio.isSilent(encode(left: [0, 0], right: [0, 0])))
        #expect(!MacAudio.isSilent(encode(left: [0, 0], right: [0, 0.01])))
    }

    @Test func macAudioRoundTripsOnTheWire() throws {
        let message = WireMessage.macAudio(encode(left: [0.5], right: [-0.25]))
        let encoded = try message.encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == message)
    }

    /// たまるまでは無音を出し、たまったら左右に分けて届いた順に出す。
    @Test func stereoWaitsForThresholdThenSplitsChannels() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 2, channelCount: 2)
        buffer.write(encode(left: [0.1], right: [-0.1]))
        #expect(read(&buffer, frames: 1) == ([0], [0]))
        buffer.write(encode(left: [0.2], right: [-0.2]))
        let played = read(&buffer, frames: 3)
        #expect(played.left == [10, 20, 0])
        #expect(played.right == [-10, -20, 0])
        #expect(buffer.underruns == 1)
    }

    /// あふれて古い音を捨てても、左右が入れ替わらない。
    @Test func stereoOverflowKeepsChannelsAligned() {
        var buffer = PCMJitterBuffer(capacity: 2, startThreshold: 1, channelCount: 2)
        buffer.write(encode(left: [0.1, 0.2, 0.3], right: [-0.1, -0.2, -0.3]))
        #expect(buffer.count == 4)
        let played = read(&buffer, frames: 2)
        #expect(played.left == [20, 30])
        #expect(played.right == [-20, -30])
    }

    /// エンジンを手で回して、届いた音がたまってから左右に分かれて鳴ることを確かめる。
    @Test func playerRendersBufferedAudioThroughEngine() throws {
        let player = MacAudioPlayer()
        let engine = try Self.offlineEngine(playing: player)
        let half = MacAudio.sampleRate / 20
        player.feed(encode(left: Array(repeating: 0.5, count: half), right: Array(repeating: -0.25, count: half)))
        #expect(try Self.render(engine, frames: 480) == ([0], [0]))
        player.feed(encode(left: Array(repeating: 0.5, count: half), right: Array(repeating: -0.25, count: half)))
        #expect(try Self.render(engine, frames: half * 2) == ([50], [-25]))
    }

    /// iPad のマイクを使っている間は、届いた音を鳴らさず捨てる。
    @Test func playerStaysSilentWhileSuppressed() throws {
        let player = MacAudioPlayer()
        let engine = try Self.offlineEngine(playing: player)
        let tenth = MacAudio.sampleRate / 10
        player.feed(encode(left: Array(repeating: 0.5, count: tenth), right: Array(repeating: 0.5, count: tenth)))
        player.setSuppressed(true)
        player.feed(encode(left: Array(repeating: 0.5, count: tenth), right: Array(repeating: 0.5, count: tenth)))
        #expect(try Self.render(engine, frames: tenth) == ([0], [0]))
        player.setSuppressed(false)
        player.feed(encode(left: Array(repeating: 0.5, count: tenth), right: Array(repeating: 0.5, count: tenth)))
        #expect(try Self.render(engine, frames: tenth) == ([50], [50]))
    }

    private static func offlineEngine(playing player: MacAudioPlayer) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.attach(player.node)
        engine.connect(player.node, to: engine.mainMixerNode, format: player.format)
        try engine.enableManualRenderingMode(.offline, format: player.format, maximumFrameCount: AVAudioFrameCount(MacAudio.sampleRate))
        try engine.start()
        return engine
    }

    /// 描いた音の左右それぞれに出てきた値 (100 倍して丸めたもの) を、重ねずに返す。
    private static func render(_ engine: AVAudioEngine, frames: Int) throws -> (left: Set<Float>, right: Set<Float>) {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)))
        #expect(try engine.renderOffline(AVAudioFrameCount(frames), to: buffer) == .success)
        let channels = try #require(buffer.floatChannelData)
        let values = { (channel: Int) in Set(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).map { ($0 * 100).rounded() }) }
        return (values(0), values(1))
    }

    /// フレームの途中で切れた分は捨て、次の塊の左右をずらさない。
    @Test func stereoDropsPartialFrames() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 1, channelCount: 2)
        buffer.write(encode(left: [0.1], right: [-0.1]) + Data([0xFF, 0x7F]))
        buffer.write(encode(left: [0.2], right: [-0.2]))
        let played = read(&buffer, frames: 2)
        #expect(played.left == [10, 20])
        #expect(played.right == [-10, -20])
    }

    /// どこかのアプリが NaN や無限大を鳴らしても、落ちずに無音か最大の音にする。
    @Test func nonFiniteSamplesDoNotTrap() {
        #expect(PadAudio.int16(.nan) == 0)
        #expect(PadAudio.int16(.infinity) == Int16.max)
        #expect(PadAudio.int16(-.infinity) == -Int16.max)
        let data = encode(left: [.nan, 0.5], right: [.infinity, -.nan])
        let values = data.withUnsafeBytes { raw in (0 ..< 4).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
        #expect(values == [0, Int16.max, 16383, 0])
        var buffer = PCMJitterBuffer(capacity: 4, startThreshold: 1)
        [Float.nan, 0.25].withUnsafeBufferPointer { buffer.write($0) }
        #expect(buffer.count == 2)
    }
}
