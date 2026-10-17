import CoreGraphics
import Foundation

/// 指のタッチの並びを、Mac のマウス操作に読み替える。
/// UIKit のジェスチャー認識を並べると、長押しとドラッグや 1 本指と 2 本指が取り合って誤認識するため、1 つの状態機械で判定する。
public struct TouchInterpreter {
    public enum Action: Equatable, Sendable {
        case move(CGPoint)
        case press(MouseButton, isDown: Bool, at: CGPoint)
        /// ビューの座標系での指の移動量。
        case scroll(dx: CGFloat, dy: CGFloat)
        /// 長押しが成立した。離せば右クリック、動かせばドラッグになる。
        case longPressRecognized
    }

    private enum State {
        case idle
        case pending(touch: Int, start: CGPoint)
        case longPressed(touch: Int, start: CGPoint)
        case dragging(touch: Int)
        case twoFinger(start: CGPoint, last: CGPoint, startTime: TimeInterval, isScrolling: Bool)
        /// 判定を終えた指が残っている間は何もしない。全部離れたら idle に戻る。
        case ignoring
    }

    public static let longPressDuration: TimeInterval = 0.5
    public var slop: CGFloat = 10
    public var twoFingerTapMaxDuration: TimeInterval = 0.35

    private var state = State.idle
    private var touches: [Int: CGPoint] = [:]

    public init() {}

    /// 長押しの判定用タイマーを動かすべき状態か。
    public var isWaitingForLongPress: Bool {
        if case .pending = state { return true }
        return false
    }

    public mutating func began(touch id: Int, at point: CGPoint, time: TimeInterval) -> [Action] {
        touches[id] = point
        switch state {
        case .idle:
            state = .pending(touch: id, start: point)
        case .pending, .longPressed:
            guard touches.count == 2 else { return [] }
            let center = centroid
            state = .twoFinger(start: center, last: center, startTime: time, isScrolling: false)
        case .dragging, .twoFinger, .ignoring:
            break
        }
        return []
    }

    public mutating func moved(touch id: Int, to point: CGPoint) -> [Action] {
        guard touches[id] != nil else { return [] }
        touches[id] = point
        switch state {
        case let .pending(touch, start), let .longPressed(touch, start):
            guard touch == id, distance(start, point) > slop else { return [] }
            state = .dragging(touch: touch)
            return [.move(start), .press(.left, isDown: true, at: start), .move(point)]
        case let .dragging(touch):
            return touch == id ? [.move(point)] : []
        case let .twoFinger(start, last, startTime, isScrolling):
            let center = centroid
            if !isScrolling {
                guard distance(start, center) > slop else { return [] }
                state = .twoFinger(start: start, last: center, startTime: startTime, isScrolling: true)
                // スクロールはカーソルの下にあるものに効くので、先に指の位置へカーソルを移す
                return [.move(start), .scroll(dx: center.x - start.x, dy: center.y - start.y)]
            }
            state = .twoFinger(start: start, last: center, startTime: startTime, isScrolling: true)
            return [.scroll(dx: center.x - last.x, dy: center.y - last.y)]
        case .idle, .ignoring:
            return []
        }
    }

    public mutating func ended(touch id: Int, at point: CGPoint, time: TimeInterval) -> [Action] {
        guard touches.removeValue(forKey: id) != nil else { return [] }
        var actions: [Action] = []
        switch state {
        case let .pending(touch, start) where touch == id:
            actions = click(.left, at: start)
        case let .longPressed(touch, start) where touch == id:
            actions = click(.right, at: start)
        case let .dragging(touch) where touch == id:
            actions = [.press(.left, isDown: false, at: point)]
        case let .twoFinger(start, _, startTime, isScrolling):
            if !isScrolling, time - startTime <= twoFingerTapMaxDuration {
                actions = click(.right, at: start)
            }
        default:
            return finishIfAllLifted()
        }
        state = .ignoring
        return actions + finishIfAllLifted()
    }

    public mutating func cancelled(touch id: Int) -> [Action] {
        guard let point = touches.removeValue(forKey: id) else { return [] }
        var actions: [Action] = []
        if case let .dragging(touch) = state, touch == id {
            actions = [.press(.left, isDown: false, at: point)]
        }
        state = .ignoring
        return actions + finishIfAllLifted()
    }

    public mutating func longPressTimerFired() -> [Action] {
        guard case let .pending(touch, start) = state else { return [] }
        state = .longPressed(touch: touch, start: start)
        return [.longPressRecognized]
    }

    private mutating func finishIfAllLifted() -> [Action] {
        if touches.isEmpty {
            state = .idle
        }
        return []
    }

    private var centroid: CGPoint {
        let points = touches.values
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func click(_ button: MouseButton, at point: CGPoint) -> [Action] {
        [.move(point), .press(button, isDown: true, at: point), .press(button, isDown: false, at: point)]
    }
}
