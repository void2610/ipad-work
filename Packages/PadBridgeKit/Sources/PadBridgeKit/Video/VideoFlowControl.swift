import Foundation
import Synchronization

/// 映像のフレームを送ってよいかを、iPad から受け取りの返事が来ていないフレームの数で決める。
/// 送り終えた知らせ (`pendingSendCount`) は OS の送信バッファに入った時点で来る。バッファは何秒分も吸い込むので、
/// それで数えると、回線が遅いときに遅れが秒単位で積み上がる (ループバックで 10 Mbps に絞って 3 秒を超えた)。
public struct VideoFlowControl: Sendable {
    /// 返事を待つフレームの数の上限。回線が詰まったときの遅れは、およそこの枚数を送る時間に収まる。
    public static let maxInFlight = 3
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

        public init(bytes: Int, busyDuration: TimeInterval?) {
            self.bytes = bytes
            self.busyDuration = busyDuration
        }
    }

    private var inFlight: [(presentationTimeMicros: Int64, isKeyFrame: Bool, bytes: Int, sentAt: TimeInterval)] = []
    private var lastAcknowledgedAt: TimeInterval?
    /// iPad が返事を返すと分かったか。返事を返さない古い iPad アプリには、送り待ちの数で間引く。
    public private(set) var isAcknowledged = false

    public init() {}

    public var inFlightCount: Int {
        inFlight.count
    }

    /// キーフレームの返事を待っているか。キーフレームは大きく、遅い回線では送るのに何枚分もかかるので、その間に捨てたフレームでビットレートを下げない。
    public var isWaitingForKeyFrame: Bool {
        inFlight.contains { $0.isKeyFrame }
    }

    /// 次のフレームを符号化して送ってよいか。
    public mutating func canSend(at time: TimeInterval) -> Bool {
        guard isAcknowledged, inFlight.count >= Self.maxInFlight else { return true }
        guard let oldest = inFlight.first, time - oldest.sentAt >= Self.stallTimeout else { return false }
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
        guard let first = delivered.first else { return Delivery(bytes: 0, busyDuration: nil) }
        let bytes = delivered.reduce(0) { $0 + $1.bytes }
        guard let previousAcknowledgedAt, first.sentAt <= previousAcknowledgedAt, time > previousAcknowledgedAt else {
            return Delivery(bytes: bytes, busyDuration: nil)
        }
        return Delivery(bytes: bytes, busyDuration: time - previousAcknowledgedAt)
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
    private var windowStart: TimeInterval?
    private var offered = 0
    private var dropped = 0
    private var busyBytes = 0
    private var busyDuration: TimeInterval = 0
    private var calmWindows = 0

    public init(maximum: Int, minimum: Int = 1_500_000) {
        self.maximum = maximum
        self.minimum = min(minimum, maximum)
        current = maximum
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
                target = max(target, Double(busyBytes * 8) / busyDuration * Self.capacityShare)
            }
            current = min(max(Int(target), minimum), current)
            calmWindows = 0
        } else if dropped == 0 {
            calmWindows += 1
            if calmWindows >= Self.calmWindowsToRaise {
                current = min(Int(Double(current) * Self.raiseFactor), maximum)
                calmWindows = 0
            }
        } else {
            calmWindows = 0
        }
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
