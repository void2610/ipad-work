import Foundation
@testable import PadBridgeKit
import Testing

struct VideoFlowControlTests {
    /// ACK が来るまでは、送信待ち数による破棄の判断に任せる (ACK を返さない古い iPad アプリで止まらない)。
    @Test func sendsFreelyUntilFirstAcknowledgement() {
        var flow = VideoFlowControl()
        var allowed: [Bool] = []
        for index in 0 ..< 10 {
            allowed.append(flow.canSend(at: Double(index) / 60))
            flow.sent(presentationTimeMicros: Int64(index), at: Double(index) / 60)
        }
        #expect(allowed == Array(repeating: true, count: 10))
    }

    /// ACK がベースの往復遅延より遅れ続けている (回線が輻輳している) ときは、ACK 待ちのフレームが 3 フレームで送信を止め、ACK が来たら送る。
    @Test func waitsForAcknowledgementWhileQueueing() {
        var flow = VideoFlowControl()
        // ベースの往復遅延は 20ms。そのあと ACK が 200ms かかるようになる
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

    /// 往復遅延が大きいだけの回線 (ここでは 100ms) では、ACK 待ちのフレームが 3 フレームを超えても送る。フレーム数で止めると毎秒 30 フレームしか送れない。
    @Test func keepsSendingOnLongRoundTrip() {
        var flow = VideoFlowControl()
        var allowed: [Bool] = []
        var maxInFlight = 0
        for index in 0 ..< 600 {
            let time = Double(index) / 60
            // 6 フレーム前のフレームの ACK が、いま届く (往復遅延 100ms)
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

    /// Wi-Fi のジッターで 1 フレームの ACK だけが大きく遅れても、直近の往復遅延の最小値はベースの往復遅延に近いので破棄しない。
    @Test func toleratesJitterSpike() {
        var flow = VideoFlowControl()
        for pts in Int64(0) ..< 30 {
            flow.sent(presentationTimeMicros: pts, at: Double(pts) / 60)
            flow.received(presentationTimeMicros: pts, at: Double(pts) / 60 + 0.03)
        }
        // 次の ACK が 250ms 来ない
        var allowed: [Bool] = []
        for pts in Int64(30) ..< 45 {
            let time = 0.5 + Double(pts - 30) / 60
            allowed.append(flow.canSend(at: time))
            flow.sent(presentationTimeMicros: pts, at: time)
        }
        #expect(allowed.allSatisfy { $0 })
    }

    /// ACK が途切れたら、途切れる前の往復遅延で輻輳していないとみなさず、0.3 秒ほどで止める (修正前は途切れた 1 秒に 31 フレームを送った)。
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
        #expect(sent <= 20, "途切れた 1 秒に \(sent) フレーム")
    }

    /// キーフレームは送信だけで時間がかかるので、その ACK の往復遅延をベースの往復遅延に混ぜない。
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

    /// 往復遅延が大きい回線でも、ACK 待ちのフレームは 30 フレームで止める。
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

    /// ACK は届いた順に来るので、後のフレームの ACK で、それより前のフレームも到達したとみなす。
    @Test func acknowledgementCoversEarlierFrames() {
        var flow = VideoFlowControl()
        for pts in Int64(1) ... 3 {
            flow.sent(presentationTimeMicros: pts, at: 0)
        }
        flow.received(presentationTimeMicros: 2)
        #expect(flow.inFlightCount == 1)
    }

    /// キャプチャを再作成する前のフレームの ACK は、新しいフレームを到達したことにしない。
    @Test func ignoresAcknowledgementOfEarlierCapture() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 500, at: 0)
        flow.received(presentationTimeMicros: 100)
        #expect(flow.inFlightCount == 1)
    }

    /// 前の ACK の時点でもう送信済みだったフレームは、前の ACK からの経過時間で到達したものとして、回線速度の推定に渡す。
    @Test func measuresDeliveryWhileLinkIsBusy() {
        var flow = VideoFlowControl()
        flow.sent(presentationTimeMicros: 1, bytes: 50_000, at: 0)
        flow.sent(presentationTimeMicros: 2, bytes: 40_000, at: 0.01)
        let first = flow.received(presentationTimeMicros: 1, at: 0.08)
        let second = flow.received(presentationTimeMicros: 2, at: 0.144)
        // 回線が空いてから送ったフレームは、空いていた時間が含まれるので推定に使わない
        flow.sent(presentationTimeMicros: 3, bytes: 40_000, at: 0.5)
        let third = flow.received(presentationTimeMicros: 3, at: 0.56)
        #expect(first.bytes == 50_000 && first.busyDuration == nil)
        #expect(second.bytes == 40_000)
        #expect(abs((second.busyDuration ?? 0) - 0.064) < 1e-9)
        #expect(third.bytes == 40_000 && third.busyDuration == nil)
        // 往復遅延は、到達したフレームを送信してから ACK が届くまで
        #expect(abs((first.roundTrip ?? 0) - 0.08) < 1e-9)
        #expect(abs((second.roundTrip ?? 0) - 0.134) < 1e-9)
        #expect(abs((third.roundTrip ?? 0) - 0.06) < 1e-9)
    }

    /// キーフレームの ACK を待つ間だけ、待機中と答える。
    @Test func tellsWhileKeyFrameIsInFlight() {
        var flow = VideoFlowControl(isAcknowledged: true)
        flow.sent(presentationTimeMicros: 1, isKeyFrame: true, at: 0)
        flow.sent(presentationTimeMicros: 2, at: 0)
        let waitingBefore = flow.isWaitingForKeyFrame
        flow.received(presentationTimeMicros: 1)
        #expect(waitingBefore)
        #expect(!flow.isWaitingForKeyFrame)
    }

    /// ACK を返さない古い iPad アプリでも、保持するフレームは増え続けず、保持したキーフレームでビットレートの見直しを止めない。
    @Test func remembersBoundedFramesWithoutAcknowledgement() {
        var flow = VideoFlowControl()
        for pts in Int64(0) ..< 1000 {
            flow.sent(presentationTimeMicros: pts, isKeyFrame: pts % 300 == 0, at: Double(pts) / 60)
        }
        #expect(flow.inFlightCount == VideoFlowControl.maxRemembered)
        #expect(!flow.isWaitingForKeyFrame)
    }

    /// 同じ iPad へのキャプチャを再作成したときは、最初の ACK を待たずに破棄する。
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

    /// ACK が来ないまま 2 秒たったら、待つのをやめて送信する。
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

/// 破棄判断とビットレートの見直しを、指定した帯域・往復遅延・ジッターの回線で 60 秒動かす (帯域は送信順に消費し、ACK は到達順に来る)。
struct VideoLinkSimulationTests {
    struct Link: CustomStringConvertible, Sendable {
        var bandwidth: Double
        var roundTrip: TimeInterval
        var jitter: TimeInterval = 0
        var description: String { "帯域 \(Int(bandwidth / 1e6)) Mbps、往復遅延 \(Int(roundTrip * 1000))ms、ジッター \(Int(jitter * 1000))ms" }
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
                // 安定したあとの 20 秒目から測る
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

    /// 帯域に余裕があれば、往復遅延が大きくてもジッターがあっても、破棄せず上限のビットレートのまま送る。
    /// ACK 待ちを 3 フレームまでにしていたときは、往復遅延 80ms で 4 割、40ms とジッター 20ms で 4 割弱を破棄し、どれも下限の 1.5 Mbps まで下げていた。
    /// 往復遅延を平滑化した平均で輻輳を判定していたときも、往復遅延 80ms とジッター 30ms では 1 割を破棄して下限まで下げた。
    @Test(arguments: [
        Link(bandwidth: 50e6, roundTrip: 0.08), Link(bandwidth: 50e6, roundTrip: 0.12),
        Link(bandwidth: 50e6, roundTrip: 0.04, jitter: 0.02), Link(bandwidth: 50e6, roundTrip: 0.08, jitter: 0.03),
    ])
    func keepsQualityWhenOnlyRoundTripIsLong(link: Link) {
        let result = run(link)
        #expect(result.droppedShare < 0.01, "\(link): 破棄した割合 \(result.droppedShare)")
        #expect(result.finalBitRate == 14_500_000, "\(link): \(result.finalBitRate)")
    }

    /// 帯域が足りずジッターもある回線では、帯域付近までは下げるが、ジッターによる破棄で下限まで下げ続けない (平均で判定していたときは 1.5 Mbps まで下げた)。
    @Test(arguments: [Link(bandwidth: 10e6, roundTrip: 0.04, jitter: 0.03), Link(bandwidth: 5e6, roundTrip: 0.08, jitter: 0.02)])
    func staysNearBandwidthOnJitteryLink(link: Link) {
        let result = run(link)
        #expect(Double(result.finalBitRate) >= link.bandwidth * 0.6, "\(link): \(result.finalBitRate)")
        // 推定帯域の上限を超えて 1.1 倍だけ試してから戻すので、試している最中なら帯域を少し超える
        #expect(Double(result.finalBitRate) <= link.bandwidth * 1.25, "\(link): \(result.finalBitRate)")
    }

    /// 帯域が足りない回線では、従来どおり破棄してビットレートを帯域まで下げ、遅延を積み上げない。
    @Test(arguments: [Link(bandwidth: 10e6, roundTrip: 0.01), Link(bandwidth: 5e6, roundTrip: 0.01), Link(bandwidth: 10e6, roundTrip: 0.08)])
    func boundsDelayWhenBandwidthIsShort(link: Link) {
        let result = run(link)
        #expect(Double(result.finalBitRate) <= link.bandwidth * 1.1, "\(link): \(result.finalBitRate)")
        // 送信してから ACK が届くまでは、往復遅延のほかに 1 フレームの送信時間と、ベースの往復遅延を超えて許容する 50ms ほどに収まる
        #expect(result.maxDelay < link.roundTrip + 0.13, "\(link): 最大 \(result.maxDelay)")
        #expect(result.meanDelay < link.roundTrip + 0.07, "\(link): 平均 \(result.meanDelay)")
    }
}

struct BitRateControllerTests {
    /// 見直しの窓 1 つ (2 秒) の間に、60fps でキャプチャし、そのうち先頭の `dropped` フレームを破棄したとして渡す。その間に変化した値を返す。
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

    /// 破棄率が 1 割を超えた窓のあと、6 割に下げる。下限より下げない。
    @Test func lowersWhenFramesAreDropped() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        let changes = (0 ..< 6).map { feed(&controller, window: $0, dropped: 60) }
        #expect(changes == [nil, 12_000_000, 7_200_000, 4_320_000, 4_000_000, nil])
    }

    /// 回線が運べる速度を推定できたら、その 85% より下げない。それ以上縮まない映像で、フレーム数ばかり減らさないため。
    @Test func lowersNoFurtherThanMeasuredCapacity() {
        var controller = BitRateController(maximum: 20_000_000)
        var changes: [Int?] = []
        for window in 0 ..< 6 {
            changes.append(feed(&controller, window: window, dropped: 60))
            // 5 Mbps の回線: その窓のうちに、39KB のフレームが 1 フレームあたり約 62ms で届いた
            for _ in 0 ..< 20 {
                controller.delivered(VideoFlowControl.Delivery(bytes: 39_000, busyDuration: 0.0624))
            }
        }
        #expect(changes == [nil, 12_000_000, 7_200_000, 4_320_000, 4_250_000, nil])
    }

    /// 推定した回線速度の 95% を上限とし、そこまでは上げるが、超えるのは破棄のない窓が 6 つ続いてから 1.1 倍だけ試す。
    /// 上限がないと、限界の 1.06 倍へ 8 秒ごとに上げては輻輳し、周期的にカクつく。
    @Test func raisesUpToCeilingThenProbesCautiously() {
        var controller = BitRateController(maximum: 20_000_000)
        var changes: [Int?] = []
        // 2 つの窓で輻輳し、5 Mbps と推定して 4.25 Mbps まで下げる (上限は 4.75 Mbps)
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

    /// 上限の 7 割より下げたら「低下中」とし、8.5 割まで戻すまでは「低下中」のままにする (境界でちらついて通知が何度も出ないように)。
    @Test func reportsReducedQualityWithHysteresis() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        var states: [Bool] = []
        for (window, dropped) in [60, 0, 0, 0, 0, 0, 0, 0].enumerated() {
            if feed(&controller, window: window, dropped: dropped) != nil {
                states.append(controller.isReduced)
            }
        }
        // 12 Mbps (6 割) で低下とし、15 Mbps (7.5 割) ではまだ低下のまま、18.75 Mbps (9.4 割) で復帰する
        #expect(states == [true, true, false])
        #expect(controller.current == 18_750_000)
        #expect(BitRateController(maximum: 20_000_000, initial: 6_000_000).isReduced)
        #expect(!BitRateController(maximum: 20_000_000).isReduced)
    }

    /// 再作成前のビットレートから始める。上限と下限の範囲に収める。
    @Test func startsFromCarriedRate() {
        #expect(BitRateController(maximum: 20_000_000, initial: 6_000_000).current == 6_000_000)
        #expect(BitRateController(maximum: 8_000_000, initial: 12_000_000).current == 8_000_000)
        #expect(BitRateController(maximum: 8_000_000, minimum: 2_000_000, initial: 500_000).current == 2_000_000)
    }

    /// ウィンドウの切り替えなどで大きな 1 フレームを送る間に破棄した分 (5 Mbps で約 9 フレーム) では下げない。
    @Test func keepsRateForSingleLargeFrame() {
        var controller = BitRateController(maximum: 20_000_000)
        let changes = (0 ..< 4).map { feed(&controller, window: $0, dropped: 9) }
        #expect(changes.allSatisfy { $0 == nil })
    }

    /// 破棄のない窓が 3 つ続いたら 1.25 倍に上げ、上限で止める。少しでも破棄した窓があればカウントし直す。
    @Test func raisesAfterCalmWindows() {
        var controller = BitRateController(maximum: 20_000_000, minimum: 4_000_000)
        let drops = [60, 0, 0, 3, 0, 0, 0, 0]
        let changes = drops.enumerated().map { feed(&controller, window: $0.offset, dropped: $0.element) }
        #expect(changes == [nil, 12_000_000, nil, nil, nil, nil, nil, 15_000_000])
    }

    /// 回線が速く一度も破棄しなければ、上限のまま変えない。
    @Test func keepsMaximumOnFastLink() {
        var controller = BitRateController(maximum: 20_000_000)
        let changes = (0 ..< 10).map { feed(&controller, window: $0, dropped: 0) }
        #expect(changes.allSatisfy { $0 == nil })
        #expect(controller.current == 20_000_000)
    }

    /// ほとんど動かないディスプレイの窓の数フレームや、間が空いたあとのカウントでは決めない。
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

    /// ACK を知らない古い Mac には、未知のメッセージを送らない。
    @Test func staysQuietUntilRequested() {
        let acknowledger = VideoAcknowledger()
        #expect(acknowledger.reply(to: .videoFrame(frame)) == nil)
    }

    /// 要求されたあとは、フレームごとにその時刻で ACK を返し、ほかのメッセージには返さない。
    @Test func acknowledgesFramesAfterRequest() {
        let acknowledger = VideoAcknowledger()
        #expect(acknowledger.reply(to: .control(.acknowledgeVideoFrames)) == nil)
        #expect(acknowledger.reply(to: .videoFrame(frame)) == .control(.videoFrameReceived(presentationTimeMicros: 42)))
        #expect(acknowledger.reply(to: .control(.requestKeyFrame)) == nil)
    }
}
