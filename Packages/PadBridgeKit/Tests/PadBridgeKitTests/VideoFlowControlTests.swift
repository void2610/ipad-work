import Foundation
@testable import PadBridgeKit
import Testing

struct VideoFlowControlTests {
    /// 返事が来るまでは、送り待ちの数で間引く側に任せる (返事を返さない古い iPad アプリで止まらない)。
    @Test func sendsFreelyUntilFirstAcknowledgement() {
        var flow = VideoFlowControl()
        var allowed: [Bool] = []
        for index in 0 ..< 10 {
            allowed.append(flow.canSend(at: Double(index) / 60))
            flow.sent(presentationTimeMicros: Int64(index), at: Double(index) / 60)
        }
        #expect(allowed == Array(repeating: true, count: 10))
    }

    /// 返事を待つフレームが上限に達したら送らず、返事が来たら送る。
    @Test func waitsForAcknowledgementWhenFull() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 1, at: 0)
        flow.received(presentationTimeMicros: 1)
        var allowed: [Bool] = []
        for pts in Int64(2) ... 4 {
            allowed.append(flow.canSend(at: 0.1))
            flow.sent(presentationTimeMicros: pts, at: 0.1)
        }
        allowed.append(flow.canSend(at: 0.2))
        flow.received(presentationTimeMicros: 2)
        allowed.append(flow.canSend(at: 0.2))
        #expect(allowed == [true, true, true, false, true])
        #expect(flow.inFlightCount == 2)
    }

    /// 返事は届いた順に来るので、あとのフレームの返事で、それより前のフレームも届いたとみなす。
    @Test func acknowledgementCoversEarlierFrames() {
        var flow = VideoFlowControl()
        for pts in Int64(1) ... 3 {
            flow.sent(presentationTimeMicros: pts, at: 0)
        }
        flow.received(presentationTimeMicros: 2)
        #expect(flow.inFlightCount == 1)
    }

    /// 取り込みを作り直す前のフレームの返事は、新しいフレームを届いたことにしない。
    @Test func ignoresAcknowledgementOfEarlierCapture() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 500, at: 0)
        flow.received(presentationTimeMicros: 100)
        #expect(flow.inFlightCount == 1)
    }

    /// 前の返事のときにもう送っていたフレームは、前の返事からの時間で届いたとして、回線の速さの見積もりに渡す。
    @Test func measuresDeliveryWhileLinkIsBusy() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 1, bytes: 50_000, at: 0)
        flow.sent(presentationTimeMicros: 2, bytes: 40_000, at: 0.01)
        let first = flow.received(presentationTimeMicros: 1, at: 0.08)
        let second = flow.received(presentationTimeMicros: 2, at: 0.144)
        // 回線が空いてから送ったフレームは、空いていた時間が入るので見積もりに使わない
        flow.sent(presentationTimeMicros: 3, bytes: 40_000, at: 0.5)
        let third = flow.received(presentationTimeMicros: 3, at: 0.56)
        #expect(first.bytes == 50_000 && first.busyDuration == nil)
        #expect(second.bytes == 40_000)
        #expect(abs((second.busyDuration ?? 0) - 0.064) < 1e-9)
        #expect(third.bytes == 40_000 && third.busyDuration == nil)
        // 往復の遅れは、届いたフレームを送ってから返事が届くまで
        #expect(abs((first.roundTrip ?? 0) - 0.08) < 1e-9)
        #expect(abs((second.roundTrip ?? 0) - 0.134) < 1e-9)
        #expect(abs((third.roundTrip ?? 0) - 0.06) < 1e-9)
    }

    /// キーフレームの返事を待つ間だけ、待っていると答える。
    @Test func tellsWhileKeyFrameIsInFlight() {
        var flow = VideoFlowControl(isAcknowledged: true)
        flow.sent(presentationTimeMicros: 1, isKeyFrame: true, at: 0)
        flow.sent(presentationTimeMicros: 2, at: 0)
        let waitingBefore = flow.isWaitingForKeyFrame
        flow.received(presentationTimeMicros: 1)
        #expect(waitingBefore)
        #expect(!flow.isWaitingForKeyFrame)
    }

    /// 返事を返さない古い iPad アプリでも、覚えておくフレームは増え続けず、覚えたキーフレームでビットレートの見直しを止めない。
    @Test func remembersBoundedFramesWithoutAcknowledgement() {
        var flow = VideoFlowControl()
        for pts in Int64(0) ..< 1000 {
            flow.sent(presentationTimeMicros: pts, isKeyFrame: pts % 300 == 0, at: Double(pts) / 60)
        }
        #expect(flow.inFlightCount == VideoFlowControl.maxRemembered)
        #expect(!flow.isWaitingForKeyFrame)
    }

    /// 同じ iPad への取り込みを作り直したときは、最初の返事を待たずに間引く。
    @Test func carriedAcknowledgementGatesFromTheStart() {
        var flow = VideoFlowControl(isAcknowledged: true)
        var allowed: [Bool] = []
        for pts in Int64(1) ... 4 {
            allowed.append(flow.canSend(at: 0))
            flow.sent(presentationTimeMicros: pts, isKeyFrame: pts == 1, at: 0)
        }
        #expect(allowed == [true, true, true, false])
        #expect(flow.isWaitingForKeyFrame)
    }

    /// 返事が来ないまま 2 秒たったら、待つのをやめて送る。
    @Test func stopsWaitingAfterStall() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 1, at: 0)
        flow.received(presentationTimeMicros: 1)
        for pts in Int64(2) ... 4 {
            flow.sent(presentationTimeMicros: pts, at: 1)
        }
        let beforeTimeout = flow.canSend(at: 2.9)
        let afterTimeout = flow.canSend(at: 3)
        #expect(!beforeTimeout)
        #expect(afterTimeout)
        #expect(flow.inFlightCount == 0)
    }
}

struct BitRateControllerTests {
    /// 見直す窓 1 つ (2 秒) の間に、60fps で取り込み、そのうち先頭の `dropped` 枚を捨てたとして渡す。その間に変わった値を返す。
    private func feed(_ controller: inout BitRateController, window: Int, dropped: Int, frames: Int = 120) -> Int? {
        var changed: Int?
        for index in 0 ..< frames {
            let time = BitRateController.window * (Double(window) + Double(index) / Double(frames))
            if let rate = controller.record(isDropped: index < dropped, at: time) {
                changed = rate
            }
        }
        return changed
    }

    /// 捨てる割合が 1 割を超えた窓のあと、6 割に下げる。下限より下げない。
    @Test func lowersWhenFramesAreDropped() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        let changes = (0 ..< 6).map { feed(&controller, window: $0, dropped: 60) }
        #expect(changes == [nil, 12_000_000, 7_200_000, 4_320_000, 4_000_000, nil])
    }

    /// 回線が運べる速さを見積もれたら、その 85% より下げない。それ以上縮まない映像で、枚数ばかり減らさないため。
    @Test func lowersNoFurtherThanMeasuredCapacity() {
        var controller = BitRateController(maximum: 20_000_000)
        var changes: [Int?] = []
        for window in 0 ..< 6 {
            changes.append(feed(&controller, window: window, dropped: 60))
            // 5 Mbps の回線: その窓のうちに、39KB のフレームが 1 枚あたり約 62ms で届いた
            for _ in 0 ..< 20 {
                controller.delivered(VideoFlowControl.Delivery(bytes: 39_000, busyDuration: 0.0624))
            }
        }
        #expect(changes == [nil, 12_000_000, 7_200_000, 4_320_000, 4_250_000, nil])
    }

    /// 見積もった回線の速さの 95% を天井にし、そこまでは上げるが、超えるのは捨てない窓が 6 つ続いてから 1.1 倍だけ試す。
    /// 天井がないと、限界の 1.06 倍へ 8 秒ごとに上げては詰まり、周期的にカクつく。
    @Test func raisesUpToCeilingThenProbesCautiously() {
        var controller = BitRateController(maximum: 20_000_000)
        var changes: [Int?] = []
        // 2 つの窓で詰まり、5 Mbps と見積もって 4.25 Mbps まで下げる (天井は 4.75 Mbps)
        for window in 0 ..< 5 {
            changes.append(feed(&controller, window: window, dropped: 60))
            for _ in 0 ..< 20 {
                controller.delivered(VideoFlowControl.Delivery(bytes: 39_000, busyDuration: 0.0624))
            }
        }
        for window in 5 ..< 15 {
            changes.append(feed(&controller, window: window, dropped: 0))
        }
        #expect(changes == [nil, 12_000_000, 7_200_000, 4_320_000, 4_250_000, nil, nil, nil, 4_750_000, nil, nil, nil, nil, nil, 5_225_000])
    }

    /// 上限の 7 割より下げたら「下げた」とし、8.5 割まで戻すまでは「下げた」のままにする (境目で揺れて知らせが何度も出ないように)。
    @Test func reportsReducedQualityWithHysteresis() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        var states: [Bool] = []
        for (window, dropped) in [60, 0, 0, 0, 0, 0, 0, 0].enumerated() {
            if feed(&controller, window: window, dropped: dropped) != nil {
                states.append(controller.isReduced)
            }
        }
        // 12 Mbps (6 割) で下げたとし、15 Mbps (7.5 割) ではまだ下げたまま、18.75 Mbps (9.4 割) で戻す
        #expect(states == [true, true, false])
        #expect(controller.current == 18_750_000)
        #expect(BitRateController(maximum: 20_000_000, initial: 6_000_000).isReduced)
        #expect(!BitRateController(maximum: 20_000_000).isReduced)
    }

    /// 作り直す前のビットレートから始める。上限と下限の中に収める。
    @Test func startsFromCarriedRate() {
        #expect(BitRateController(maximum: 20_000_000, initial: 6_000_000).current == 6_000_000)
        #expect(BitRateController(maximum: 8_000_000, initial: 12_000_000).current == 8_000_000)
        #expect(BitRateController(maximum: 8_000_000, minimum: 2_000_000, initial: 500_000).current == 2_000_000)
    }

    /// 窓を切り替えたときなどの大きな 1 枚を送る間に捨てた分 (5 Mbps で約 9 枚) では下げない。
    @Test func keepsRateForSingleLargeFrame() {
        var controller = BitRateController(maximum: 20_000_000)
        let changes = (0 ..< 4).map { feed(&controller, window: $0, dropped: 9) }
        #expect(changes.allSatisfy { $0 == nil })
    }

    /// 捨てない窓が 3 つ続いたら 1.25 倍に上げ、上限で止める。少しでも捨てた窓があれば数え直す。
    @Test func raisesAfterCalmWindows() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        let drops = [60, 0, 0, 3, 0, 0, 0, 0]
        let changes = drops.enumerated().map { feed(&controller, window: $0.offset, dropped: $0.element) }
        #expect(changes == [nil, 12_000_000, nil, nil, nil, nil, nil, 15_000_000])
    }

    /// 回線が速く一度も捨てなければ、上限のまま変えない。
    @Test func keepsMaximumOnFastLink() {
        var controller = BitRateController(maximum: 20_000_000)
        let changes = (0 ..< 10).map { feed(&controller, window: $0, dropped: 0) }
        #expect(changes.allSatisfy { $0 == nil })
        #expect(controller.current == 20_000_000)
    }

    /// 画面がほとんど動かない窓の数枚や、間が空いたあとの数え方では決めない。
    @Test func ignoresSparseFramesAndGaps() {
        var controller = BitRateController(maximum: 20_000_000)
        var changes = [feed(&controller, window: 0, dropped: 5, frames: 10), feed(&controller, window: 1, dropped: 5, frames: 10)]
        changes.append(controller.record(isDropped: true, at: BitRateController.window * 1.5))
        changes.append(controller.record(isDropped: false, at: BitRateController.window * 10))
        #expect(changes.allSatisfy { $0 == nil })
        #expect(controller.current == 20_000_000)
    }
}

struct VideoAcknowledgerTests {
    private let frame = VideoFrame(isKeyFrame: false, presentationTimeMicros: 42, data: Data([1, 2, 3]))

    /// 返事を知らない古い Mac には、知らないメッセージを送らない。
    @Test func staysQuietUntilRequested() {
        let acknowledger = VideoAcknowledger()
        #expect(acknowledger.reply(to: .videoFrame(frame)) == nil)
    }

    /// 求められたあとは、フレームごとにその時刻で返事をし、ほかのメッセージには返さない。
    @Test func acknowledgesFramesAfterRequest() {
        let acknowledger = VideoAcknowledger()
        #expect(acknowledger.reply(to: .control(.acknowledgeVideoFrames)) == nil)
        #expect(acknowledger.reply(to: .videoFrame(frame)) == .control(.videoFrameReceived(presentationTimeMicros: 42)))
        #expect(acknowledger.reply(to: .control(.requestKeyFrame)) == nil)
    }
}
