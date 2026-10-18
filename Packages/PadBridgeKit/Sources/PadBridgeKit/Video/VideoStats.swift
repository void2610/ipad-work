import Foundation
import Synchronization

/// Mac が送っている映像の状態。遅い・カクつくと感じたときに、iPad の「接続の状態」で原因の見当を付けられるようにする。
public struct VideoStats: Codable, Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// 回線に合わせて決めた今の平均のビットレート。
    public var bitRate: Int
    public var maximumBitRate: Int
    /// Mac がフレームを送ってから、iPad の受け取りの返事が届くまで (ミリ秒、ならした値)。返事を返さない iPad では nil。
    public var roundTripMillis: Int?
    /// 取り込む毎秒の枚数の上限。iPad が低電力モードなどで少なく頼んだときに分かるように。
    public var frameRate: Int?

    public init(codec: VideoCodec, width: Int, height: Int, bitRate: Int, maximumBitRate: Int, roundTripMillis: Int?, frameRate: Int? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.maximumBitRate = maximumBitRate
        self.roundTripMillis = roundTripMillis
        self.frameRate = frameRate
    }

    /// 往復の遅れは 1 枚ごとに揺れるので、新しい値を 2 割ずつ混ぜてならす。
    public static func smoothed(_ previous: TimeInterval?, with sample: TimeInterval) -> TimeInterval {
        previous.map { $0 * 0.8 + sample * 0.2 } ?? sample
    }
}

/// iPad で、届いた映像の枚数と量を数える。届いたキューで数え、画面に出すときにまとめて読む。
public final class ReceiveRateMeter: Sendable {
    private struct Counts {
        var frames = 0
        var bytes = 0
        var since: TimeInterval?
    }

    private let counts = Mutex(Counts())

    public init() {}

    public func record(bytes: Int, at time: TimeInterval) {
        counts.withLock {
            if $0.since == nil { $0.since = time }
            $0.frames += 1
            $0.bytes += bytes
        }
    }

    /// 映像を止めたときに呼ぶ。次の映像の最初のフレームから数え始め、止めていた時間で割らないようにする。
    public func reset() {
        counts.withLock { $0 = Counts() }
    }

    /// 前に読んでからの毎秒の枚数と Mbps を返し、数え直す。1 枚も届いていなければ 0。
    public func take(at time: TimeInterval) -> (framesPerSecond: Double, megabitsPerSecond: Double) {
        counts.withLock { counts in
            defer { counts = Counts(frames: 0, bytes: 0, since: time) }
            guard let since = counts.since, time > since else { return (0, 0) }
            let seconds = time - since
            return (Double(counts.frames) / seconds, Double(counts.bytes * 8) / seconds / 1_000_000)
        }
    }
}
