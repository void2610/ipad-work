import Foundation

/// 連続したクリックを数える。合成したマウスイベントには macOS がクリック回数を付けてくれないため、自前で数える。
public struct ClickCounter: Sendable {
    private struct Press: Sendable {
        var button: MouseButton
        var x: Double
        var y: Double
        var time: TimeInterval
        var count: Int
    }

    public var interval: TimeInterval
    public var maxDistance: Double
    private var last: Press?

    public init(interval: TimeInterval, maxDistance: Double) {
        self.interval = interval
        self.maxDistance = maxDistance
    }

    public mutating func registerDown(button: MouseButton, x: Double, y: Double, time: TimeInterval) -> Int {
        var count = 1
        if let last, last.button == button, time - last.time <= interval, hypot(x - last.x, y - last.y) <= maxDistance {
            count = last.count + 1
        }
        last = Press(button: button, x: x, y: y, time: time, count: count)
        return count
    }
}
