import Foundation
@testable import PadBridgeKit
import Testing

/// ペアリングなしで、同じ LAN の誰でもつなげる。壊れたデータや極端な値が届いても、読み取りで止まらないこと。
struct WireFuzzTests {
    /// 決まった並びの乱数 (毎回同じ中身で試す)。
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    private static let samples: [WireMessage] = [
        .control(.scroll(dx: 0.1, dy: -0.2)),
        .control(.displays([RemoteDisplay(id: 1, name: "画面", placement: .left)], shownID: 1)),
        .videoFormat(VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: [Data([1, 2, 3]), Data([4, 5]), Data([6])])),
        .videoFrame(VideoFrame(isKeyFrame: true, presentationTimeMicros: 42, region: VideoRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5), data: Data(repeating: 7, count: 64))),
        .audio(Data([1, 0, 2, 0])),
        .macAudio(Data([1, 0, 2, 0])),
        .macAudioOpus(Data([0xFC, 0xFF])),
    ]

    /// どの種類にでたらめな中身が届いても、エラーを返すか何かに読めるだけで止まらない。
    @Test func randomPayloadsNeverCrash() {
        var random = Random(state: 1)
        for type in UInt32(0) ... 8 {
            for _ in 0 ..< 500 {
                let payload = Data((0 ..< Int(random.next() % 96)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
                _ = try? WireMessage(type: type, payload: payload)
            }
        }
    }

    /// 正しいメッセージを途中で切ったものと、1 バイトずつ壊したものも、止まらずに読める。
    @Test func truncatedAndCorruptedMessagesNeverCrash() throws {
        for message in Self.samples {
            let encoded = try message.encoded()
            for length in 0 ... encoded.payload.count {
                _ = try? WireMessage(type: encoded.type, payload: encoded.payload.prefix(length))
            }
            for index in encoded.payload.indices {
                var corrupted = encoded.payload
                corrupted[index] ^= 0xFF
                _ = try? WireMessage(type: encoded.type, payload: corrupted)
            }
        }
    }

    /// 映像の範囲に NaN や無限大が届いても、画面の中に収まった範囲として読む (iPad の表示の位置が壊れない)。
    @Test func videoRegionFromWireIsAlwaysUsable() throws {
        for values in [[Double.nan, 0, 1, 1], [0, 0, .infinity, 1], [-5, 9, 0, -1], [0.9, 0.9, 0.5, 0.5]] {
            var writer = ByteWriter()
            writer.write(UInt8(1))
            writer.write(Int64(0))
            values.forEach { writer.write($0.bitPattern) }
            let message = try WireMessage(type: 3, payload: writer.data)
            guard case let .videoFrame(frame) = message else { Issue.record("フレームに読めない"); continue }
            let region = frame.region
            let isFinite = [region.x, region.y, region.width, region.height].allSatisfy { $0.isFinite }
            #expect(isFinite)
            #expect(region.width > 0 && region.height > 0 && region.x >= 0 && region.y >= 0)
            #expect(region.x + region.width <= 1 && region.y + region.height <= 1)
        }
        // JSON で届く範囲も同じく収める
        let json = Data(#"{"videoRegion":{"_0":{"x":-1,"y":0.5,"width":3,"height":0.5}}}"#.utf8)
        #expect(try JSONDecoder().decode(ControlMessage.self, from: json) == .videoRegion(VideoRegion(x: 0, y: 0.5, width: 1, height: 0.5)))
    }

    /// 極端なスクロールの量が届いても、ホイールの量は上限に収まる (Int32 に収まらずに止まらない)。
    @Test func hugeScrollStaysWithinWheelRange() throws {
        let json = Data(#"{"scroll":{"dx":1e300,"dy":-1e300}}"#.utf8)
        guard case let .scroll(dx, dy) = try JSONDecoder().decode(ControlMessage.self, from: json) else {
            Issue.record("スクロールに読めない")
            return
        }
        var wheel = ScrollWheel()
        let pixels = wheel.pixels(dx: dx, dy: dy, width: 3840, height: 2160)
        let invalid = wheel.pixels(dx: .nan, dy: .infinity, width: 3840, height: 2160)
        #expect(pixels?.x == Int32(ScrollWheel.maxPixels))
        #expect(pixels?.y == -Int32(ScrollWheel.maxPixels))
        #expect(invalid == nil)
    }

    /// ゆっくり動かしたときの 1 ピクセル未満の移動は、持ち越して消さない (0.35 ピクセルを 10 回で 3 ピクセル)。
    @Test func slowScrollCarriesFraction() {
        var wheel = ScrollWheel()
        var total: Int32 = 0
        for _ in 0 ..< 10 {
            let pixels = wheel.pixels(dx: 0, dy: 0.00035, width: 1000, height: 1000)
            total += pixels?.y ?? 0
        }
        #expect(total == 3)
    }
}
