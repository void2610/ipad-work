import Foundation
@testable import PadBridgeKit
import Testing

struct PreferredFrameRateTests {
    /// ふだんは 60 枚、低電力モードか本体が熱い (serious 以上) ときは 30 枚を頼む。
    @Test(arguments: [
        (false, ProcessInfo.ThermalState.nominal, 60),
        (false, .fair, 60),
        (false, .serious, 30),
        (false, .critical, 30),
        (true, .nominal, 30),
    ])
    func choosesFrameRate(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, expected: Int) {
        #expect(PreferredFrameRate.choose(isLowPowerMode: isLowPowerMode, thermalState: thermalState) == expected)
    }

    /// 減らしたあとは、熱さが fair に下がっただけでは戻さず、nominal まで冷えたら戻す。熱さの境の揺れで頼み直し続けない。
    @Test func returnsToNormalOnlyWhenCool() {
        let saving = PreferredFrameRate.saving
        #expect(PreferredFrameRate.choose(isLowPowerMode: false, thermalState: .fair, current: saving) == saving)
        #expect(PreferredFrameRate.choose(isLowPowerMode: false, thermalState: .serious, current: saving) == saving)
        #expect(PreferredFrameRate.choose(isLowPowerMode: false, thermalState: .nominal, current: saving) == PreferredFrameRate.normal)
    }

    /// 頼んだ枚数は操作用の接続で送り、状態には取り込みの枚数が入る。
    @Test func frameRateTravelsOnTheWire() throws {
        let messages: [ControlMessage] = [
            .videoFrameRate(30),
            .videoStats(VideoStats(codec: .h264, width: 1920, height: 1080, bitRate: 8_000_000, maximumBitRate: 8_294_400, roundTripMillis: nil, frameRate: 30)),
        ]
        for message in messages {
            let encoded = try WireMessage.control(message).encoded()
            #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == .control(message))
        }
    }

    /// 枚数の項目がない前の版の状態も読める。
    @Test func decodesStatsWithoutFrameRate() throws {
        let json = Data(#"{"videoStats":{"_0":{"codec":1,"width":10,"height":10,"bitRate":1,"maximumBitRate":2}}}"#.utf8)
        let message = try JSONDecoder().decode(ControlMessage.self, from: json)
        #expect(message == .videoStats(VideoStats(codec: .hevc, width: 10, height: 10, bitRate: 1, maximumBitRate: 2, roundTripMillis: nil)))
    }
}
