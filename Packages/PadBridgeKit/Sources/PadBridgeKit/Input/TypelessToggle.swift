import Foundation

/// Typeless のショートカットは押すたびに開始と完了が入れ替わるだけなので、Typeless の実際の状態を見て、iPad の求める状態にするために押すかどうかを決める。
/// iPad 側の覚えだけで押すと、Typeless が自分で聞き取りを終えたときなどに、iPad の表示と開始・完了が逆になる。
public struct TypelessToggle: Sendable {
    /// 押してから Typeless のマイクが動き出す (止まる) までの猶予。この間は、まだ反映されていない押した結果を今の状態とみなす。
    public static let settleTime: TimeInterval = 1

    /// iPad が始めさせた聞き取りが続いているか。iPad が離れたときに、Mac で自分で始めた聞き取りまで止めないために覚える。
    public private(set) var isStartedByPad = false
    private var expected: (isActive: Bool, since: TimeInterval)?

    public init() {}

    /// iPad から `isActive` を求められたときに呼ぶ。ショートカットを押すべきなら true を返し、押したものとして覚える。
    public mutating func shouldPress(toBecome isActive: Bool, isRecording: Bool, at time: TimeInterval) -> Bool {
        isStartedByPad = isActive
        guard current(isRecording: isRecording, at: time) != isActive else { return false }
        expected = (isActive, time)
        return true
    }

    /// Typeless のマイクが動き出したり止まったりしたときに呼ぶ。
    public mutating func observe(isRecording: Bool) {
        if expected?.isActive == isRecording {
            expected = nil
        }
        if !isRecording {
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
