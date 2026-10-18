import Foundation
import Synchronization

/// 映像のフレームを送ってよいかを、iPad から受信確認 (ACK) が届いていないフレームの数で決める。
/// 送信完了の通知 (`pendingSendCount`) は OS の送信バッファに入った時点で届く。バッファは何秒分も吸い込むので、
/// それで数えると、回線が遅いときに遅延が秒単位で積み上がる (ループバックで 10 Mbps に絞って 3 秒を超えた)。
public struct VideoFlowControl: Sendable {
    /// ACK を待つフレームがこの数に達したら、ACK が遅れていないかを見る。RTT の見積もりがないうちは、この数で止める。
    public static let maxInFlight = 3
    /// ベースの往復遅延を超えて、ACK の遅れをここまで許す (60fps で 3 フレーム分)。輻輳したときの遅延は、およそこの時間に収まる。
    public static let queueingAllowance: TimeInterval = 0.05
    /// RTT が長い回線でも、ACK を待つフレームはこれより増やさない。
    public static let maxInFlightOnSlowRoundTrip = 30
    // ベースの往復遅延は、最近の RTT の最小値。経路が変わって長くなったときに追従できるよう、この秒数ごとに測り直す (短いと、輻輳中の値が混ざって膨らむ)
    static let roundTripWindow: TimeInterval = 30
    /// ACK が来ないまま待ち続けないよう、この秒数を過ぎたら待つのをやめる。
    public static let stallTimeout: TimeInterval = 2

    // ACK を返さない古い iPad アプリのときに、記憶しておくフレーム数の上限
    static let maxRemembered = 120

    /// ACK で到達が確認できた分。
    public struct Delivery: Sendable, Equatable {
        public var bytes: Int
        /// 前の ACK の時点で送信済みだったフレームなら、前の ACK からの経過時間 (回線が埋まっていて、この時間で届いた)。
        /// 回線が空いてから送ったフレームは、待機時間が含まれるので速度の見積もりに使わない。
        public var busyDuration: TimeInterval?
        /// 到達したうちの最後のフレームを送ってから、ACK が届くまで。iPad の「接続の状態」に表示する。
        public var roundTrip: TimeInterval?

        public init(bytes: Int, busyDuration: TimeInterval?, roundTrip: TimeInterval? = nil) {
            self.bytes = bytes
            self.busyDuration = busyDuration
            self.roundTrip = roundTrip
        }
    }

    private var inFlight: [(presentationTimeMicros: Int64, isKeyFrame: Bool, bytes: Int, sentAt: TimeInterval)] = []
    private var lastAcknowledgedAt: TimeInterval?
    private var roundTripMinimum: (since: TimeInterval, value: TimeInterval)?
    private var previousRoundTripMinimum: TimeInterval?
    // 直近の RTT。Wi-Fi のジッターなら一部だけが遅れ、回線が輻輳するとどれも遅れるので、この中の最小値で見分ける (平均で見るとジッターによる大きな遅れに引かれ、RTT 80ms・ジッター 30ms の回線で下限まで下げた)
    private var recentRoundTrips: [(time: TimeInterval, value: TimeInterval)] = []
    // 60fps で 9 フレームほど。0.1 秒だとジッターで全部が遅れた窓を輻輳と誤判定し (RTT 80ms・ジッター 30ms で 3.1 Mbps まで下げた)、0.2 秒だと輻輳に気づくまでに遅延が積み上がった
    static let recentWindow: TimeInterval = 0.15
    // ACK がこれだけ来なければ、途絶したとみなす。ジッターで ACK の間隔が 0.15 秒空くことはあるので、直近の窓より長くする (同じ長さだと、RTT 80ms・ジッター 30ms で 5.2 Mbps まで下げた)
    static let acknowledgementGap: TimeInterval = 0.3
    /// iPad が ACK を返すと判明したか。ACK を返さない古い iPad アプリには、送信待ちの数で破棄する。
    public private(set) var isAcknowledged = false

    /// `isAcknowledged` は、同じ iPad へのキャプチャを作り直したときに引き継ぐ。最初の ACK を待つ間は破棄しないので、遅い回線では遅延がたまる。
    public init(isAcknowledged: Bool = false) {
        self.isAcknowledged = isAcknowledged
    }

    public var inFlightCount: Int {
        inFlight.count
    }

    /// キーフレームの ACK を待っているか。キーフレームは大きく、遅い回線では送信に何フレーム分もかかるので、その間に破棄したフレームでビットレートを下げない。
    /// ACK が来ない間はそもそも破棄しない。ACK を返さない古い iPad アプリでは、記憶しているキーフレームが消えないので待っているとみなさない。
    public var isWaitingForKeyFrame: Bool {
        isAcknowledged && inFlight.contains { $0.isKeyFrame }
    }

    /// ベースの往復遅延 (最近の ACK の RTT の最小値)。ACK がまだなければ nil。
    public var baseRoundTrip: TimeInterval? {
        [roundTripMinimum?.value, previousRoundTripMinimum].compactMap(\.self).min()
    }

    /// 次のフレームをエンコードして送ってよいか。
    public mutating func canSend(at time: TimeInterval) -> Bool {
        guard isAcknowledged, inFlight.count >= Self.maxInFlight, let oldest = inFlight.first else { return true }
        // RTT が長いだけの回線では、ACK を待つフレームが増えても遅延は積み上がらない。フレーム数で止めると、帯域に余裕があっても 3 フレーム ÷ RTT しか送れず
        // (RTT 80ms で毎秒 37 フレーム)、破棄した分でビットレートを下限まで下げていた。直近の RTT の最小値がベースの往復遅延に近い間は、ジッターで遅れても破棄しない
        if let base = baseRoundTrip, inFlight.count < Self.maxInFlightOnSlowRoundTrip {
            // ACK が途絶したら、途絶する前の小さな RTT で輻輳していないとみなさない (途絶した 1 秒に 30 フレームを送り込んだ)
            let isFresh = recentRoundTrips.last.map { time - $0.time <= Self.acknowledgementGap } ?? false
            let recent = recentRoundTrips.map(\.value).min()
            let isQueueing = !isFresh || recent.map { $0 - base >= Self.queueingAllowance } ?? true
            if !isQueueing || time - oldest.sentAt < base + Self.queueingAllowance {
                return true
            }
        }
        guard time - oldest.sentAt >= Self.stallTimeout else { return false }
        inFlight.removeAll()
        return true
    }

    public mutating func sent(presentationTimeMicros: Int64, isKeyFrame: Bool = false, bytes: Int = 0, at time: TimeInterval) {
        inFlight.append((presentationTimeMicros, isKeyFrame, bytes, time))
        if inFlight.count > Self.maxRemembered {
            inFlight.removeFirst(inFlight.count - Self.maxRemembered)
        }
    }

    /// ACK は到着順に届くので、そのフレームまでを到達したものとする。前のキャプチャのフレームの ACK は、どれにも当たらない。
    @discardableResult
    public mutating func received(presentationTimeMicros: Int64, at time: TimeInterval = 0) -> Delivery {
        isAcknowledged = true
        let count = inFlight.prefix { $0.presentationTimeMicros <= presentationTimeMicros }.count
        let delivered = inFlight.prefix(count)
        let previousAcknowledgedAt = lastAcknowledgedAt
        inFlight.removeFirst(count)
        lastAcknowledgedAt = time
        guard let first = delivered.first, let last = delivered.last else { return Delivery(bytes: 0, busyDuration: nil) }
        let bytes = delivered.reduce(0) { $0 + $1.bytes }
        let roundTrip = time - last.sentAt
        // キーフレームは送信だけで時間がかかるので、その RTT をベースの往復遅延に混ぜない (作り直した直後の最初の ACK はキーフレーム)
        if !last.isKeyFrame {
            recordRoundTrip(roundTrip, at: time)
        }
        guard let previousAcknowledgedAt, first.sentAt <= previousAcknowledgedAt, time > previousAcknowledgedAt else {
            return Delivery(bytes: bytes, busyDuration: nil, roundTrip: roundTrip)
        }
        return Delivery(bytes: bytes, busyDuration: time - previousAcknowledgedAt, roundTrip: roundTrip)
    }

    private mutating func recordRoundTrip(_ roundTrip: TimeInterval, at time: TimeInterval) {
        guard roundTrip >= 0 else { return }
        recentRoundTrips.append((time, roundTrip))
        recentRoundTrips.removeAll { time - $0.time > Self.recentWindow }
        if let current = roundTripMinimum, time - current.since < Self.roundTripWindow {
            roundTripMinimum = (current.since, min(current.value, roundTrip))
        } else {
            previousRoundTripMinimum = roundTripMinimum?.value
            roundTripMinimum = (time, roundTrip)
        }
    }
}

/// 輻輳してフレームを破棄した割合から、映像の平均ビットレートを決める。
/// 輻輳したまま同じサイズのフレームを送ると、破棄されて動きがカクつくので、1 フレームを小さくしてフレーム数を保つ。
/// ただし回線の転送速度より下げない。それ以上縮まない映像では、エンコーダがフレームを落として合わせるので、フレーム数が減るだけになる。
public struct BitRateController: Sendable {
    /// 2 秒ごとに見直す。1 秒だと、ウィンドウを切り替えたときなどの大きな 1 フレームを送る間に破棄した分 (5 Mbps で約 9 フレーム) だけで下げてしまう
    public static let window: TimeInterval = 2
    // 破棄した割合がこれを超えたら下げる
    static let dropRatioToLower = 0.1
    static let lowerFactor = 0.6
    static let raiseFactor = 1.25
    // 回線容量の上限を超えて試すときの、上げ幅と待つ窓の数。回線の限界のすぐ上へ何度も上げて輻輳させ、周期的にカクつかないように
    static let probeFactor = 1.1
    static let calmWindowsToProbe = 6
    // 回線容量の上限は、見積もった回線速度のこの割合
    static let ceilingShare = 0.95
    // 上限のこの割合より下げたら「画質低下」、この割合まで戻したら「復帰」とする。境目で上下して通知が何度も出ないよう、2 つを離す
    static let reducedBelow = 0.7
    static let restoredAtOrAbove = 0.85
    // 見積もった回線速度のうち、映像に使う割合。残りはジッターと Mac のサウンドに回す
    static let capacityShare = 0.85
    // 回線が埋まっていた時間がこれより短いと、速度を見積もらない
    static let minimumBusyDuration: TimeInterval = 0.2
    // 破棄のない窓がこれだけ続いたら上げる
    static let calmWindowsToRaise = 3
    // ディスプレイがほとんど動かない間の数フレームでは、割合を判定しない
    static let minimumFramesToJudge = 20

    public let maximum: Int
    public let minimum: Int
    public private(set) var current: Int
    /// 回線に合わせて、上限より大きく下げているか。iPad に画質低下を通知するのに使う。
    public private(set) var isReduced = false
    private var windowStart: TimeInterval?
    private var offered = 0
    private var dropped = 0
    private var busyBytes = 0
    private var busyDuration: TimeInterval = 0
    private var calmWindows = 0
    // 下げたときに見積もった回線速度から決めた回線容量の上限。ここまでは上げてよいが、超えるのは慎重に試す
    private var ceiling: Int?

    /// `initial` は、同じ iPad へのキャプチャを作り直す前のビットレート。回線は変わっていないので、上限から測り直さない。
    public init(maximum: Int, minimum: Int = 1_500_000, initial: Int? = nil) {
        self.maximum = maximum
        self.minimum = min(minimum, maximum)
        current = min(max(initial ?? maximum, self.minimum), maximum)
        updateReduced()
    }

    /// ACK が届くたびに呼ぶ。回線が埋まっていた間に届いた量から、回線速度を見積もる。
    public mutating func delivered(_ delivery: VideoFlowControl.Delivery) {
        guard let duration = delivery.busyDuration else { return }
        busyBytes += delivery.bytes
        busyDuration += duration
    }

    /// キャプチャしたフレームごとに呼ぶ。`isDropped` は、輻輳していて送らずに破棄したか。ビットレートを変えるときだけ新しい値を返す。
    public mutating func record(isDropped: Bool, at time: TimeInterval) -> Int? {
        guard let start = windowStart else {
            begin(at: time, isDropped: isDropped)
            return nil
        }
        guard time - start >= Self.window else {
            offered += 1
            dropped += isDropped ? 1 : 0
            return nil
        }
        // ディスプレイが止まっていて間が空いたときは、直前の数フレームで判定せず数え直す
        let isStale = time - start >= Self.window * 2
        let previous = current
        if !isStale, offered >= Self.minimumFramesToJudge {
            judge()
            updateReduced()
        }
        begin(at: time, isDropped: isDropped)
        return current == previous ? nil : current
    }

    private mutating func begin(at time: TimeInterval, isDropped: Bool) {
        windowStart = time
        offered = 1
        dropped = isDropped ? 1 : 0
        busyBytes = 0
        busyDuration = 0
    }

    private mutating func judge() {
        if Double(dropped) / Double(offered) >= Self.dropRatioToLower {
            var target = Double(current) * Self.lowerFactor
            if busyDuration >= Self.minimumBusyDuration {
                let capacity = Double(busyBytes * 8) / busyDuration
                target = max(target, capacity * Self.capacityShare)
                ceiling = Int(capacity * Self.ceilingShare)
            }
            current = min(max(Int(target), minimum), current)
            calmWindows = 0
        } else if dropped == 0 {
            calmWindows += 1
            raiseIfCalm()
        } else {
            calmWindows = 0
        }
    }

    private mutating func updateReduced() {
        if !isReduced, Double(current) < Double(maximum) * Self.reducedBelow {
            isReduced = true
        } else if isReduced, Double(current) >= Double(maximum) * Self.restoredAtOrAbove {
            isReduced = false
        }
    }

    private mutating func raiseIfCalm() {
        guard current < maximum else { return }
        if let ceiling, current >= ceiling {
            // 回線が速くなったかを確かめるときだけ、上限を少し超えてみる
            guard calmWindows >= Self.calmWindowsToProbe else { return }
            current = min(Int(Double(current) * Self.probeFactor), maximum)
            self.ceiling = nil
        } else {
            guard calmWindows >= Self.calmWindowsToRaise else { return }
            let raised = min(Int(Double(current) * Self.raiseFactor), maximum)
            current = ceiling.map { min(raised, $0) } ?? raised
        }
        calmWindows = 0
    }
}

/// iPad 側で、映像用の接続ごとに作る。Mac に要求されたら、受信したフレームごとに ACK を作る。
public final class VideoAcknowledger: Sendable {
    private let isRequested = Atomic(false)

    public init() {}

    /// 映像用の接続で受信したメッセージに対して、Mac へ返すメッセージ。
    public func reply(to message: WireMessage) -> WireMessage? {
        switch message {
        case .control(.acknowledgeVideoFrames):
            isRequested.store(true, ordering: .relaxed)
            return nil
        case let .videoFrame(frame) where isRequested.load(ordering: .relaxed):
            return .control(.videoFrameReceived(presentationTimeMicros: frame.presentationTimeMicros))
        default:
            return nil
        }
    }
}
