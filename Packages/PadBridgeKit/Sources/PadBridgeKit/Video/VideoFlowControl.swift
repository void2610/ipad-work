import Foundation
import Synchronization

/// 映像のフレームを送ってよいかを、iPad から受け取りの返事が来ていないフレームの数で決める。
/// 送り終えた知らせ (`pendingSendCount`) は OS の送信バッファに入った時点で来る。バッファは何秒分も吸い込むので、
/// それで数えると、回線が遅いときに遅れが秒単位で積み上がる (ループバックで 10 Mbps に絞って 3 秒を超えた)。
public struct VideoFlowControl: Sendable {
    /// 返事を待つフレームがこの数に達したら、返事が遅れていないかを見る。往復の見積もりがないうちは、この数で止める。
    public static let maxInFlight = 3
    /// いつもの往復の時間を超えて、返事の遅れをここまで許す (60fps で 3 枚分)。回線が詰まったときの遅れは、およそこの時間に収まる。
    public static let queueingAllowance: TimeInterval = 0.05
    /// 往復が長い回線でも、返事を待つフレームはこれより増やさない。
    public static let maxInFlightOnSlowRoundTrip = 30
    // いつもの往復の時間は、最近の往復の最小値。経路が変わって長くなったときに追えるよう、この秒数ごとに測り直す (短いと、詰まっている間の値が混ざって膨らむ)
    static let roundTripWindow: TimeInterval = 30
    /// 返事が来ないまま待ち続けないよう、この秒数を過ぎたら待つのをやめる。
    public static let stallTimeout: TimeInterval = 2

    // 返事を返さない古い iPad アプリのときに、覚えておくフレームの数の上限
    static let maxRemembered = 120

    /// 返事で届いたと分かった分。
    public struct Delivery: Sendable, Equatable {
        public var bytes: Int
        /// 前の返事のときにはもう送っていたフレームなら、前の返事からの時間 (回線が埋まっていて、これだけの時間で届いた)。
        /// 回線が空いてから送ったフレームは、待っていた時間が入るので速さの見積もりに使わない。
        public var busyDuration: TimeInterval?
        /// 届いたうちの最後のフレームを送ってから、返事が届くまで。iPad に「接続の状態」として見せる。
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
    // 直近の往復。Wi-Fi の揺れなら一部だけが遅れ、回線に詰まるとどれも遅れるので、この中の最小値で見分ける (平均で見ると揺れの大きな遅れに引かれ、往復 80ms・揺れ 30ms の回線で下限まで下げた)
    private var recentRoundTrips: [(time: TimeInterval, value: TimeInterval)] = []
    // 60fps で 9 枚ほど。0.1 秒だと揺れで全部が遅れた窓を詰まりと取り (往復 80ms・揺れ 30ms で 3.1 Mbps まで下げた)、0.2 秒だと詰まりに気づくまでに遅れが積み上がった
    static let recentWindow: TimeInterval = 0.15
    // 返事がこれだけ来なければ、途切れたとみなす。揺れで返事の間が 0.15 秒空くことはあるので、直近の窓より長くする (同じ長さだと、往復 80ms・揺れ 30ms で 5.2 Mbps まで下げた)
    static let acknowledgementGap: TimeInterval = 0.3
    /// iPad が返事を返すと分かったか。返事を返さない古い iPad アプリには、送り待ちの数で間引く。
    public private(set) var isAcknowledged = false

    /// `isAcknowledged` は、同じ iPad への取り込みを作り直したときに引き継ぐ。最初の返事を待つ間は間引かないので、遅い回線では遅れがたまる。
    public init(isAcknowledged: Bool = false) {
        self.isAcknowledged = isAcknowledged
    }

    public var inFlightCount: Int {
        inFlight.count
    }

    /// キーフレームの返事を待っているか。キーフレームは大きく、遅い回線では送るのに何枚分もかかるので、その間に捨てたフレームでビットレートを下げない。
    /// 返事が来ない間はそもそも間引かない。返事を返さない古い iPad アプリでは、覚えているキーフレームが消えないので待っているとみなさない。
    public var isWaitingForKeyFrame: Bool {
        isAcknowledged && inFlight.contains { $0.isKeyFrame }
    }

    /// いつもの往復の時間 (最近の返事の往復の最小値)。返事がまだなければ nil。
    public var baseRoundTrip: TimeInterval? {
        [roundTripMinimum?.value, previousRoundTripMinimum].compactMap(\.self).min()
    }

    /// 次のフレームを符号化して送ってよいか。
    public mutating func canSend(at time: TimeInterval) -> Bool {
        guard isAcknowledged, inFlight.count >= Self.maxInFlight, let oldest = inFlight.first else { return true }
        // 往復が長いだけの回線では、返事を待つ枚数が増えても遅れは積み上がらない。枚数で止めると、帯域に余裕があっても 3 枚 ÷ 往復しか送れず
        // (往復 80ms で毎秒 37 枚)、捨てた分でビットレートを下限まで下げていた。直近の往復の最小値がいつもの往復に近い間は、揺れで遅れても捨てない
        if let base = baseRoundTrip, inFlight.count < Self.maxInFlightOnSlowRoundTrip {
            // 返事が途切れたら、途切れる前の小さな往復で詰まっていないとみなさない (途切れた 1 秒に 30 枚を送り込んだ)
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

    /// 届いた順に返事が来るので、そのフレームまでを届いたものとする。前の取り込みのフレームの返事は、どれにも当たらない。
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
        // キーフレームは送るだけで時間がかかるので、その往復をいつもの往復に混ぜない (作り直した直後の最初の返事はキーフレーム)
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

/// 回線が詰まってフレームを捨てた割合から、映像の平均のビットレートを決める。
/// 詰まったまま同じ大きさのフレームを送ると、間引かれて動きがカクつくので、1 枚を小さくして枚数を保つ。
/// ただし回線が運べる速さより下げない。それ以上縮まない映像では、エンコーダがフレームを落として合わせるので、枚数が減るだけになる。
public struct BitRateController: Sendable {
    /// 2 秒ごとに見直す。1 秒だと、窓を切り替えたときなどの大きな 1 枚を送る間に捨てた分 (5 Mbps で約 9 枚) だけで下げてしまう
    public static let window: TimeInterval = 2
    // 捨てた割合がこれを超えたら下げる
    static let dropRatioToLower = 0.1
    static let lowerFactor = 0.6
    static let raiseFactor = 1.25
    // 天井を超えて試すときの、上げる幅と待つ窓の数。回線の限界のすぐ上へ何度も上げて詰まらせ、周期的にカクつかないように
    static let probeFactor = 1.1
    static let calmWindowsToProbe = 6
    // 天井は、見積もった回線の速さのこの割合
    static let ceilingShare = 0.95
    // 上限のこの割合より下げたら「画質を下げた」、この割合まで戻したら「戻した」とする。境目で揺れて知らせが何度も出ないよう、2 つを離す
    static let reducedBelow = 0.7
    static let restoredAtOrAbove = 0.85
    // 見積もった回線の速さのうち、映像に使う割合。残りは揺れと Mac の音に回す
    static let capacityShare = 0.85
    // 回線が埋まっていた時間がこれより短いと、速さを見積もらない
    static let minimumBusyDuration: TimeInterval = 0.2
    // 捨てない窓がこれだけ続いたら上げる
    static let calmWindowsToRaise = 3
    // 画面がほとんど動かない間の数枚では、割合を決めない
    static let minimumFramesToJudge = 20

    public let maximum: Int
    public let minimum: Int
    public private(set) var current: Int
    /// 回線に合わせて、上限より大きく下げているか。iPad に画質を下げたことを知らせるのに使う。
    public private(set) var isReduced = false
    private var windowStart: TimeInterval?
    private var offered = 0
    private var dropped = 0
    private var busyBytes = 0
    private var busyDuration: TimeInterval = 0
    private var calmWindows = 0
    // 下げたときに見積もった回線の速さから決めた天井。ここまでは上げてよいが、超えるのは慎重に試す
    private var ceiling: Int?

    /// `initial` は、同じ iPad への取り込みを作り直す前のビットレート。回線は変わっていないので、上限から測り直さない。
    public init(maximum: Int, minimum: Int = 1_500_000, initial: Int? = nil) {
        self.maximum = maximum
        self.minimum = min(minimum, maximum)
        current = min(max(initial ?? maximum, self.minimum), maximum)
        updateReduced()
    }

    /// 返事が来るたびに呼ぶ。回線が埋まっていた間に届いた量から、回線の速さを見積もる。
    public mutating func delivered(_ delivery: VideoFlowControl.Delivery) {
        guard let duration = delivery.busyDuration else { return }
        busyBytes += delivery.bytes
        busyDuration += duration
    }

    /// 取り込んだフレームごとに呼ぶ。`isDropped` は、回線が詰まっていて送らずに捨てたか。ビットレートを変えるときだけ新しい値を返す。
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
        // 画面が止まっていて間が空いたときは、前の数枚で決めず数え直す
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
            // 回線が速くなったかを確かめるときだけ、天井を少し超えてみる
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

/// iPad 側で、映像用の接続ごとに作る。Mac に求められたら、受け取ったフレームごとに返事を作る。
public final class VideoAcknowledger: Sendable {
    private let isRequested = Atomic(false)

    public init() {}

    /// 映像用の接続で受け取ったメッセージに対して、Mac へ返すメッセージ。
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
