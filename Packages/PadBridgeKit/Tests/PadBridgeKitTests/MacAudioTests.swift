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

    /// バッファが溜まるまでは無音を出力し、溜まったら左右に分けて届いた順に出力する。
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

    /// あふれて古い音声を破棄しても、左右が入れ替わらない。
    @Test func stereoOverflowKeepsChannelsAligned() {
        var buffer = PCMJitterBuffer(capacity: 2, startThreshold: 1, channelCount: 2)
        buffer.write(encode(left: [0.1, 0.2, 0.3], right: [-0.1, -0.2, -0.3]))
        #expect(buffer.count == 4)
        let played = read(&buffer, frames: 2)
        #expect(played.left == [20, 30])
        #expect(played.right == [-20, -30])
    }

    /// エンジンを手動で駆動し、届いた音声が溜まってから左右に分かれて再生されることを確認する。
    @Test func playerRendersBufferedAudioThroughEngine() throws {
        let player = MacAudioPlayer()
        let engine = try Self.offlineEngine(playing: player)
        let half = MacAudio.sampleRate / 20
        player.feed(encode(left: Array(repeating: 0.5, count: half), right: Array(repeating: -0.25, count: half)))
        #expect(try Self.render(engine, frames: 480) == ([0], [0]))
        player.feed(encode(left: Array(repeating: 0.5, count: half), right: Array(repeating: -0.25, count: half)))
        #expect(try Self.render(engine, frames: half * 2) == ([50], [-25]))
    }

    /// iPad のマイクを使っている間は、届いた音声を再生せず破棄する。
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

    /// iPad で受信する形式と同じく、Opus のパケットを渡して再生する。再生を停止して再開したあとも同じく再生される。
    @Test func playerRendersOpusPacketsThroughEngine() throws {
        let player = MacAudioPlayer()
        #expect(player.canDecodeOpus)
        let engine = try Self.offlineEngine(playing: player)
        let encoder = try #require(MacAudioEncoder())
        var chunkIndex = 0
        // 左にだけ 440Hz・0.5 の正弦波を入れた 20ms のチャンクを、Opus にエンコードして渡す
        func feedChunks(_ count: Int) {
            for _ in 0 ..< count {
                let left = (0 ..< MacAudio.chunkFrames).map { Float(sin(2 * Double.pi * 440 * Double(chunkIndex * MacAudio.chunkFrames + $0) / Double(MacAudio.sampleRate)) * 0.5) }
                let right = [Float](repeating: 0, count: MacAudio.chunkFrames)
                let chunk = left.withUnsafeBufferPointer { left in right.withUnsafeBufferPointer { MacAudio.encode(left: left, right: $0) } }
                encoder.encode(chunk).forEach(player.feedOpus)
                chunkIndex += 1
            }
        }
        for round in 0 ..< 2 {
            feedChunks(25)
            // 溜まり始めの 100ms とエンコード先頭の遅延を越えたところから、200ms を測る
            let (left, right) = try Self.renderSamples(engine, frames: MacAudio.sampleRate * 3 / 10)
            let rms = { (samples: ArraySlice<Float>) in sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)) }
            let steadyLeft = left[(MacAudio.sampleRate / 10)...]
            let steadyRight = right[(MacAudio.sampleRate / 10)...]
            #expect(abs(rms(steadyLeft) - 0.354) < 0.05, "\(round + 1) 回目の左の実効値 \(rms(steadyLeft))")
            #expect(rms(steadyRight) < 0.02, "\(round + 1) 回目の右の実効値 \(rms(steadyRight))")
            player.reset()
        }
    }

    private static func renderSamples(_ engine: AVAudioEngine, frames: Int) throws -> (left: [Float], right: [Float]) {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)))
        #expect(try engine.renderOffline(AVAudioFrameCount(frames), to: buffer) == .success)
        let channels = try #require(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: channels[0], count: count)), Array(UnsafeBufferPointer(start: channels[1], count: count)))
    }

    private static func offlineEngine(playing player: MacAudioPlayer) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.attach(player.node)
        engine.connect(player.node, to: engine.mainMixerNode, format: player.format)
        try engine.enableManualRenderingMode(.offline, format: player.format, maximumFrameCount: AVAudioFrameCount(MacAudio.sampleRate))
        try engine.start()
        return engine
    }

    /// レンダリングした音声の左右それぞれの値 (100 倍して丸めたもの) を、重複なく返す。
    private static func render(_ engine: AVAudioEngine, frames: Int) throws -> (left: Set<Float>, right: Set<Float>) {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)))
        #expect(try engine.renderOffline(AVAudioFrameCount(frames), to: buffer) == .success)
        let channels = try #require(buffer.floatChannelData)
        let values = { (channel: Int) in Set(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).map { ($0 * 100).rounded() }) }
        return (values(0), values(1))
    }

    /// フレームの途中で切れた分は破棄し、次のチャンクの左右をずらさない。
    @Test func stereoDropsPartialFrames() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 1, channelCount: 2)
        buffer.write(encode(left: [0.1], right: [-0.1]) + Data([0xFF, 0x7F]))
        buffer.write(encode(left: [0.2], right: [-0.2]))
        let played = read(&buffer, frames: 2)
        #expect(played.left == [10, 20])
        #expect(played.right == [-10, -20])
    }

    /// どこかのアプリが NaN や無限大を再生しても、クラッシュせず無音か最大音量にする。
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

    /// 輻輳して一度に届きあふれたら、再生開始時のバッファ量まで減らし、遅延を残さない。左右はずれない。
    @Test func overflowTrimsBackToThreshold() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 2, channelCount: 2, trimsOnOverflow: true)
        let left = (1 ... 11).map { Float($0) / 100 }
        buffer.write(encode(left: left, right: left.map { -$0 }))
        #expect(buffer.count == 6)
        let played = read(&buffer, frames: 3)
        #expect(played.left == [9, 10, 11])
        #expect(played.right == [-9, -10, -11])
    }

    /// iPad の音声入力のように破棄したくない音声は、従来どおり古い方から 1 つずつ破棄する。
    @Test func overflowWithoutTrimDropsOneAtATime() {
        var buffer = PCMJitterBuffer(capacity: 10, startThreshold: 2, channelCount: 2)
        let left = (1 ... 11).map { Float($0) / 100 }
        buffer.write(encode(left: left, right: left.map { -$0 }))
        #expect(buffer.count == 20)
    }
}
