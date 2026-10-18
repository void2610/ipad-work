import Foundation
@testable import PadBridgeKit
import Testing

struct VideoStatsTests {
    /// 往復の遅れは、1 枚の揺れで跳ねないよう 2 割ずつ混ぜる。
    @Test func smoothsRoundTrip() {
        #expect(VideoStats.smoothed(nil, with: 0.05) == 0.05)
        #expect(abs(VideoStats.smoothed(0.05, with: 0.15) - 0.07) < 1e-12)
    }

    /// 前に読んでからの枚数と量を、毎秒に直して返し、数え直す。
    @Test func meterReportsRatesSinceLastTake() {
        let meter = ReceiveRateMeter()
        #expect(meter.take(at: 10) == (0, 0))
        for index in 0 ..< 30 {
            meter.record(bytes: 25_000, at: 10 + Double(index) / 30)
        }
        let rate = meter.take(at: 12)
        #expect(rate.framesPerSecond == 15)
        #expect(rate.megabitsPerSecond == 3)
        #expect(meter.take(at: 14) == (0, 0))
    }

    /// 映像を止めて 1 分後に戻っても、止めていた間で割らず、戻ってからの最初のフレームから数える。
    @Test func meterStartsAfterResetFromFirstFrame() {
        let meter = ReceiveRateMeter()
        meter.record(bytes: 25_000, at: 0)
        _ = meter.take(at: 2)
        meter.reset()
        for index in 0 ..< 60 {
            meter.record(bytes: 25_000, at: 62 + Double(index) / 30)
        }
        let rate = meter.take(at: 64)
        #expect(rate.framesPerSecond == 30)
        #expect(rate.megabitsPerSecond == 6)
    }

    /// Mac のメニューには 1 行にまとめて出す。下げていることや減らした枚数は、そのときだけ書く。
    @Test func summarizesForMenu() {
        let full = VideoStats(codec: .hevc, width: 2360, height: 1532, bitRate: 14_462_080, maximumBitRate: 14_462_080, roundTripMillis: 12, frameRate: 60)
        #expect(full.summary == "HEVC 2360×1532・14.5 Mbps・RTT 12 ms")
        let reduced = VideoStats(codec: .h264, width: 1920, height: 1080, bitRate: 4_000_000, maximumBitRate: 8_294_400, roundTripMillis: nil, frameRate: 30)
        #expect(reduced.summary == "H.264 1920×1080・4.0 Mbps (回線状況に合わせて低下中)・最大 30 fps")
    }

    /// 「接続の状態」は操作用の接続で送るので、JSON で往復できる。
    @Test func statsRoundTripOnTheWire() throws {
        let stats = VideoStats(codec: .hevc, width: 2360, height: 1532, bitRate: 8_000_000, maximumBitRate: 14_462_080, roundTripMillis: 42)
        let encoded = try WireMessage.control(.videoStats(stats)).encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == .control(.videoStats(stats)))
    }
}
