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

    /// 返事がいつもの往復より遅れ続けている (回線に詰まっている) ときは、返事を待つフレームが 3 枚で止め、返事が来たら送る。
    @Test func waitsForAcknowledgementWhileQueueing() {
        var flow = VideoFlowControl()
        // いつもの往復は 20ms。そのあと返事が 200ms かかるようになる
        flow.sent(presentationTimeMicros: 1, at: 0)
        flow.received(presentationTimeMicros: 1, at: 0.02)
        for pts in Int64(2) ... 20 {
            flow.sent(presentationTimeMicros: pts, at: Double(pts) / 10)
            flow.received(presentationTimeMicros: pts, at: Double(pts) / 10 + 0.2)
        }
        var allowed: [Bool] = []
        for pts in Int64(21) ... 23 {
            allowed.append(flow.canSend(at: 3))
            flow.sent(presentationTimeMicros: pts, at: 3)
        }
        allowed.append(flow.canSend(at: 3.1))
        flow.received(presentationTimeMicros: 21, at: 3.1)
        allowed.append(flow.canSend(at: 3.1))
        #expect(allowed == [true, true, true, false, true])
        #expect(flow.inFlightCount == 2)
    }

    /// 往復が長いだけの回線 (ここでは 100ms) では、返事を待つフレームが 3 枚を超えても送る。枚数で止めると毎秒 30 枚しか送れない。
    @Test func keepsSendingOnLongRoundTrip() {
        var flow = VideoFlowControl()
        var allowed: [Bool] = []
        var maxInFlight = 0
        for index in 0 ..< 600 {
            let time = Double(index) / 60
            // 6 枚前のフレームの返事が、いま届く (往復 100ms)
            if index >= 6 {
                flow.received(presentationTimeMicros: Int64(index - 6), at: time)
            }
            allowed.append(flow.canSend(at: time))
            flow.sent(presentationTimeMicros: Int64(index), at: time)
            maxInFlight = max(maxInFlight, flow.inFlightCount)
        }
        #expect(allowed.allSatisfy { $0 })
        #expect(maxInFlight == 6)
        #expect(abs((flow.baseRoundTrip ?? 0) - 0.1) < 1e-9)
    }

    /// Wi-Fi の揺れで 1 枚の返事だけが大きく遅れても、直近の往復の最小値はいつもの往復に近いので捨てない。
    @Test func toleratesJitterSpike() {
        var flow = VideoFlowControl()
        for pts in Int64(0) ..< 30 {
            flow.sent(presentationTimeMicros: pts, at: Double(pts) / 60)
            flow.received(presentationTimeMicros: pts, at: Double(pts) / 60 + 0.03)
        }
        // 次の返事が 250ms 来ない
        var allowed: [Bool] = []
        for pts in Int64(30) ..< 45 {
            let time = 0.5 + Double(pts - 30) / 60
            allowed.append(flow.canSend(at: time))
            flow.sent(presentationTimeMicros: pts, at: time)
        }
        #expect(allowed.allSatisfy { $0 })
    }

    /// 返事が途切れたら、途切れる前の往復で詰まっていないとみなさず、0.3 秒ほどで止める (直す前は途切れた 1 秒に 31 枚を送った)。
    @Test func stopsSoonAfterAcknowledgementsStop() {
        var flow = VideoFlowControl()
        for pts in Int64(0) ..< 60 {
            flow.sent(presentationTimeMicros: pts, at: Double(pts) / 60)
            flow.received(presentationTimeMicros: pts, at: Double(pts) / 60 + 0.01)
        }
        var sent = 0
        for pts in Int64(60) ..< 120 {
            let time = Double(pts) / 60
            if flow.canSend(at: time) {
                flow.sent(presentationTimeMicros: pts, at: time)
                sent += 1
            }
        }
        #expect(sent <= 20, "途切れた 1 秒に \(sent) 枚")
    }

    /// キーフレームは送るだけで時間がかかるので、その返事の往復をいつもの往復に混ぜない。
    @Test func ignoresKeyFrameRoundTrip() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 1, isKeyFrame: true, at: 0)
        flow.received(presentationTimeMicros: 1, at: 0.4)
        let afterKeyFrame = flow.baseRoundTrip
        flow.sent(presentationTimeMicros: 2, at: 0.5)
        flow.received(presentationTimeMicros: 2, at: 0.52)
        #expect(afterKeyFrame == nil)
        #expect(abs((flow.baseRoundTrip ?? 0) - 0.02) < 1e-9)
    }

    /// 往復が長い回線でも、返事を待つフレームは 30 枚で止める。
    @Test func capsFramesInFlight() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 0, at: 0)
        flow.received(presentationTimeMicros: 0, at: 0.01)
        var sent = 0
        for pts in Int64(1) ... 40 where flow.canSend(at: 1) {
            flow.sent(presentationTimeMicros: pts, at: 1)
            sent += 1
        }
        #expect(sent == VideoFlowControl.maxInFlightOnSlowRoundTrip)
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
        var flow = VideoFlowControl(isAcknowledged: true)
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

/// 間引きとビットレートの見直しを、決めた帯域・往復・揺れの回線で 60 秒動かす (帯域は送った順に使い、返事は届いた順に来る)。
struct VideoLinkSimulationTests {
    struct Link: CustomStringConvertible, Sendable {
        var bandwidth: Double
        var roundTrip: TimeInterval
        var jitter: TimeInterval = 0
        var description: String { "帯域 \(Int(bandwidth / 1e6)) Mbps、往復 \(Int(roundTrip * 1000))ms、揺れ \(Int(jitter * 1000))ms" }
    }

    struct Result {
        var droppedShare: Double
        var finalBitRate: Int
        var meanDelay: TimeInterval
        var maxDelay: TimeInterval
    }

    private func run(_ link: Link, maximum: Int = 14_500_000) -> Result {
        var seed: UInt64 = 42
        func uniform() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var flow = VideoFlowControl(isAcknowledged: true)
        var controller = BitRateController(maximum: maximum)
        var acks: [(time: TimeInterval, pts: Int64, sentAt: TimeInterval)] = []
        var linkFreeAt = 0.0
        var lastAckAt = 0.0
        var dropped = 0
        var delays: [TimeInterval] = []
        for index in 0 ..< 3600 {
            let time = Double(index) / 60
            while let first = acks.first, first.time <= time {
                acks.removeFirst()
                controller.delivered(flow.received(presentationTimeMicros: first.pts, at: first.time))
                // 落ち着いたあとの 20 秒目から測る
                if first.time > 20 { delays.append(first.time - first.sentAt) }
            }
            let canSend = flow.canSend(at: time)
            _ = controller.record(isDropped: !canSend, at: time)
            guard canSend else {
                dropped += 1
                continue
            }
            let bytes = controller.current / 8 / 60
            linkFreeAt = max(time, linkFreeAt) + Double(bytes * 8) / link.bandwidth
            let extra = link.jitter > 0 ? -log(max(uniform(), 1e-9)) * link.jitter : 0
            lastAckAt = max(linkFreeAt + link.roundTrip + extra, lastAckAt)
            flow.sent(presentationTimeMicros: Int64(index), bytes: bytes, at: time)
            acks.append((lastAckAt, Int64(index), time))
        }
        return Result(
            droppedShare: Double(dropped) / 3600, finalBitRate: controller.current,
            meanDelay: delays.reduce(0, +) / Double(max(delays.count, 1)), maxDelay: delays.max() ?? 0
        )
    }

    /// 帯域に余裕があれば、往復が長くても揺れがあっても、捨てずに上限のビットレートのまま送る。
    /// 返事を待つのを 3 枚までにしていたときは、往復 80ms で 4 割、40ms と揺れ 20ms で 4 割弱を捨て、どれも下限の 1.5 Mbps まで下げていた。
    /// 往復をならした平均で詰まりを見ていたときも、往復 80ms と揺れ 30ms では 1 割を捨てて下限まで下げた。
    @Test(arguments: [
        Link(bandwidth: 50e6, roundTrip: 0.08), Link(bandwidth: 50e6, roundTrip: 0.12),
        Link(bandwidth: 50e6, roundTrip: 0.04, jitter: 0.02), Link(bandwidth: 50e6, roundTrip: 0.08, jitter: 0.03),
    ])
    func keepsQualityWhenOnlyRoundTripIsLong(link: Link) {
        let result = run(link)
        #expect(result.droppedShare < 0.01, "\(link): 捨てた割合 \(result.droppedShare)")
        #expect(result.finalBitRate == 14_500_000, "\(link): \(result.finalBitRate)")
    }

    /// 帯域が足りず揺れもある回線では、帯域の近くまでは下げるが、揺れで捨てた分で下限まで下げ続けない (平均で見ていたときは 1.5 Mbps まで下げた)。
    @Test(arguments: [Link(bandwidth: 10e6, roundTrip: 0.04, jitter: 0.03), Link(bandwidth: 5e6, roundTrip: 0.08, jitter: 0.02)])
    func staysNearBandwidthOnJitteryLink(link: Link) {
        let result = run(link)
        #expect(Double(result.finalBitRate) >= link.bandwidth * 0.6, "\(link): \(result.finalBitRate)")
        // 天井を超えて 1.1 倍だけ試してから戻すので、試している最中なら帯域を少し超える
        #expect(Double(result.finalBitRate) <= link.bandwidth * 1.25, "\(link): \(result.finalBitRate)")
    }

    /// 帯域が足りない回線では、これまでどおり捨ててビットレートを帯域まで下げ、遅れを積み上げない。
    @Test(arguments: [Link(bandwidth: 10e6, roundTrip: 0.01), Link(bandwidth: 5e6, roundTrip: 0.01), Link(bandwidth: 10e6, roundTrip: 0.08)])
    func boundsDelayWhenBandwidthIsShort(link: Link) {
        let result = run(link)
        #expect(Double(result.finalBitRate) <= link.bandwidth * 1.1, "\(link): \(result.finalBitRate)")
        // 送ってから返事が届くまでは、往復のほかに 1 枚を送る時間と、いつもの往復を超えて許す 50ms ほどに収まる
        #expect(result.maxDelay < link.roundTrip + 0.13, "\(link): 最大 \(result.maxDelay)")
        #expect(result.meanDelay < link.roundTrip + 0.07, "\(link): 平均 \(result.meanDelay)")
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
