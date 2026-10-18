import Foundation

/// Typeless のショートカットは押すたびに開始と完了が交互に切り替わるだけなので、Typeless の実際の状態を見て、iPad が求める状態にするために押すかどうかを決める。
/// iPad 側の記憶だけで押すと、Typeless が自分で音声入力を終えたときなどに、iPad の表示と開始・完了が逆になる。
public struct TypelessToggle: Sendable {
    /// 押してから Typeless のマイクが動き出す (止まる) までの猶予。この間は、まだ反映されていない押下の結果を現在の状態とみなす。
    public static let settleTime: TimeInterval = 1

    /// iPad が開始させた音声入力が続いているか。iPad が切断されたときに、Mac で自分で開始した音声入力まで止めないために保持する。
    public private(set) var isStartedByPad = false
    private var expected: (isActive: Bool, since: TimeInterval)?

    public init() {}

    /// iPad から `isActive` を求められたときに呼ぶ。ショートカットを押すべきなら true を返し、押したものとして記憶する。
    public mutating func shouldPress(toBecome isActive: Bool, isRecording: Bool, at time: TimeInterval) -> Bool {
        isStartedByPad = isActive
        guard current(isRecording: isRecording, at: time) != isActive else { return false }
        expected = (isActive, time)
        return true
    }

    /// Typeless のマイクが動き出したり止まったりしたときに呼ぶ。
    public mutating func observe(isRecording: Bool, at time: TimeInterval) {
        // 開始を押した直後に届いた「止まった」は、監視が遅れて検知した前回の音声入力の終了。iPad が開始させたことは忘れない (忘れると、iPad が切断されたときに止めない)
        let isStaleStop = !isRecording && expected.map { $0.isActive && time - $0.since < Self.settleTime } == true
        if expected?.isActive == isRecording {
            expected = nil
        }
        if !isRecording, !isStaleStop {
            isStartedByPad = false
        }
    }

    private func current(isRecording: Bool, at time: TimeInterval) -> Bool {
        if let expected, time - expected.since < Self.settleTime {
            return expected.isActive
        }
        return isRecording
    }
}
