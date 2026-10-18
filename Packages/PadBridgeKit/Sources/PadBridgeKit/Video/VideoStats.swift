import Foundation
import Synchronization

/// Mac が送っている映像の状態。遅延やカクつきを感じたときに、iPad の「接続の状態」で原因の見当を付けられるようにする。
public struct VideoStats: Codable, Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// 回線に合わせて決めた現在の平均ビットレート。
    public var bitRate: Int
    public var maximumBitRate: Int
    /// Mac がフレームを送ってから、iPad の ACK が届くまで (ミリ秒、平滑化した値)。ACK を返さない iPad では nil。
    public var roundTripMillis: Int?
    /// キャプチャのフレームレートの上限。iPad が低電力モードなどで低く要求したときに分かるように。
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

    /// 1 行にまとめた状態。Mac のメニューに表示する。
    public var summary: String {
        var parts = ["\(codec == .hevc ? "HEVC" : "H.264") \(width)×\(height)", String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)]
        if bitRate < maximumBitRate {
            parts[1] += " (回線状況に合わせて低下中)"
        }
        if let frameRate, frameRate < PreferredFrameRate.normal {
            parts.append("最大 \(frameRate) fps")
        }
        if let roundTripMillis {
            parts.append("RTT \(roundTripMillis) ms")
        }
        return parts.joined(separator: "・")
    }

    /// RTT は 1 フレームごとにジッターがあるので、新しい値を 2 割ずつ混ぜて平滑化する。
    public static func smoothed(_ previous: TimeInterval?, with sample: TimeInterval) -> TimeInterval {
        previous.map { $0 * 0.8 + sample * 0.2 } ?? sample
    }
}

/// iPad で、受信した映像のフレーム数とデータ量を数える。受信したキューで数え、画面に表示するときにまとめて読む。
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

    /// 映像を止めたときに呼ぶ。次の映像の最初のフレームから数え始め、停止していた時間で割らないようにする。
    public func reset() {
        counts.withLock { $0 = Counts() }
    }

    /// 前に読んでからの fps と Mbps を返し、数え直す。1 フレームも届いていなければ 0。
    public func take(at time: TimeInterval) -> (framesPerSecond: Double, megabitsPerSecond: Double) {
        counts.withLock { counts in
            defer { counts = Counts(frames: 0, bytes: 0, since: time) }
            guard let since = counts.since, time > since else { return (0, 0) }
            let seconds = time - since
            return (Double(counts.frames) / seconds, Double(counts.bytes * 8) / seconds / 1_000_000)
        }
    }
}
