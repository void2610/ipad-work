import CoreGraphics
import Foundation

/// 指のタッチ列を、Mac のマウス操作に変換する。
/// UIKit のジェスチャー認識を並べると、長押しとドラッグや 1 本指と 2 本指が競合して誤認識するため、1 つの状態機械で判定する。
public struct TouchInterpreter {
    public enum Action: Equatable, Sendable {
        case move(CGPoint)
        case press(MouseButton, isDown: Bool, at: CGPoint)
        /// ビューの座標系での指の移動量。
        case scroll(dx: CGFloat, dy: CGFloat)
        /// 指が離れた時点のスクロールの速さ (ビューの座標系で pt/秒)。慣性スクロールに使う。
        case scrollEnded(velocityX: CGFloat, velocityY: CGFloat)
        /// 長押しが成立した。離せば右クリック、動かせばドラッグになる。
        case longPressRecognized
        /// 3 本指でスワイプした。指が動いた向き。
        case threeFingerSwipe(SwipeDirection)
        /// ディスプレイの下端から上へスワイプした。iPad で Dock を表示するのと同じ操作で、Mac の Dock を表示する。
        case bottomEdgeSwipe
        /// 2 本指でピンチした。`center` を中心に前回から `scale` 倍し、指の中心が動いた分 `translation` だけ移動する。
        case zoom(scale: CGFloat, center: CGPoint, translation: CGVector)
    }

    public enum SwipeDirection: String, Codable, Equatable, Sendable {
        case left
        case right
        case up
        case down
    }

    private enum State {
        case idle
        case pending(touch: Int, start: CGPoint, startTime: TimeInterval, fromBottomEdge: Bool)
        case longPressed(touch: Int, start: CGPoint)
        case dragging(touch: Int)
        case twoFingerPending(start: CGPoint, startTime: TimeInterval, startSpan: CGFloat)
        case pinching(lastCenter: CGPoint, lastSpan: CGFloat)
        case scrolling(last: CGPoint, lastTime: TimeInterval)
        case threeFinger(start: CGPoint, hasSwiped: Bool)
        /// 判定を終えた指が残っている間は何もしない。全部離れたら idle に戻る。
        case ignoring
    }

    public static let longPressDuration: TimeInterval = 0.5
    public var slop: CGFloat = 10
    public var twoFingerTapMaxDuration: TimeInterval = 0.35
    // 指を止めてから離したときに、慣性スクロールしないようにするための猶予
    public var flickTimeout: TimeInterval = 0.08
    public var threeFingerSwipeDistance: CGFloat = 50
    /// ディスプレイの下端の位置 (ビューの座標系)。ここから `bottomEdgeZone` 以内で触れ始めて上へスワイプすると `bottomEdgeSwipe` になる。
    public var bottomEdge: CGFloat = .infinity
    public var bottomEdgeZone: CGFloat = 24
    public var bottomEdgeSwipeDistance: CGFloat = 30
    /// 2 本指の間隔がこれだけ変わったら、スクロールではなくピンチ (拡大・縮小) とみなす。
    public var pinchThreshold: CGFloat = 24
    // 複数の指は同時には着地しないので、1 本目が動いてもしばらくは 1 本指のスクロールと決めずに他の指を待つ
    public var multiFingerGrace: TimeInterval = 0.08

    private var state = State.idle
    private var scrollStartTime: TimeInterval = 0
    /// スクロール開始からこれより後に触れた 3 本目は、スワイプの意図ではなく親指や手のひらとみなす (指をずらして置く人の残りの指は数十 ms で触れる)。
    public var lateThirdFinger: TimeInterval = 0.25
    private var touches: [Int: CGPoint] = [:]
    private var velocity = CGVector.zero

    public init() {}

    /// 長押しの判定用タイマーを動かすべき状態か。
    public var isWaitingForLongPress: Bool {
        if case .pending = state { return true }
        return false
    }

    public mutating func began(touch id: Int, at point: CGPoint, time: TimeInterval) -> [Action] {
        touches[id] = point
        if touches.count == 3 {
            if case let .scrolling(_, lastTime) = state, time - scrollStartTime > lateThirdFinger {
                // 指が増えると重心が飛ぶので、そこを新しい基準にしてスクロールを続ける
                state = .scrolling(last: centroid, lastTime: lastTime)
                return []
            }
            return beginThreeFinger()
        }
        switch state {
        case .idle:
            state = .pending(touch: id, start: point, startTime: time, fromBottomEdge: point.y >= bottomEdge - bottomEdgeZone)
        case .pending, .longPressed:
            guard touches.count == 2 else { return [] }
            state = .twoFingerPending(start: centroid, startTime: time, startSpan: span)
        case let .scrolling(_, lastTime):
            // 指が増えると重心が飛ぶので、そこを新しい基準にする。慣性スクロールの判定に使う最後に動いた時刻は保持する
            state = .scrolling(last: centroid, lastTime: lastTime)
        case .dragging, .twoFingerPending, .pinching, .threeFinger, .ignoring:
            break
        }
        return []
    }

    public mutating func moved(touch id: Int, to point: CGPoint, time: TimeInterval) -> [Action] {
        guard touches[id] != nil else { return [] }
        touches[id] = point
        switch state {
        case let .pending(touch, start, startTime, fromBottomEdge):
            guard touch == id, distance(start, point) > slop else { return [] }
            // 下端から上へ向かう間は、スクロールと決めずにスワイプの完了を待つ
            if fromBottomEdge, start.y - point.y > abs(point.x - start.x) {
                guard start.y - point.y >= bottomEdgeSwipeDistance else { return [] }
                state = .ignoring
                return [.bottomEdgeSwipe]
            }
            guard time - startTime >= multiFingerGrace else { return [] }
            velocity = .zero
            state = .scrolling(last: point, lastTime: time)
            scrollStartTime = time
            // スクロールはカーソルの下にあるものに効くので、先に指の位置へカーソルを移す
            return [.move(start), .scroll(dx: point.x - start.x, dy: point.y - start.y)]
        case let .longPressed(touch, start):
            guard touch == id, distance(start, point) > slop else { return [] }
            state = .dragging(touch: touch)
            return [.move(start), .press(.left, isDown: true, at: start), .move(point)]
        case let .dragging(touch):
            return touch == id ? [.move(point)] : []
        case let .twoFingerPending(start, _, startSpan):
            let center = centroid
            // 間隔の変化が中心の移動より大きければ、スワイプではなくピンチとみなす
            if touches.count == 2, abs(span - startSpan) > pinchThreshold, abs(span - startSpan) > distance(start, center) {
                state = .pinching(lastCenter: center, lastSpan: span)
                return [.zoom(scale: span / max(startSpan, 1), center: center, translation: CGVector(dx: center.x - start.x, dy: center.y - start.y))]
            }
            guard distance(start, center) > slop else { return [] }
            velocity = .zero
            state = .scrolling(last: center, lastTime: time)
            scrollStartTime = time
            return [.move(start), .scroll(dx: center.x - start.x, dy: center.y - start.y)]
        case let .pinching(lastCenter, lastSpan):
            guard touches.count == 2 else { return [] }
            let center = centroid
            let span = span
            state = .pinching(lastCenter: center, lastSpan: span)
            return [.zoom(scale: span / max(lastSpan, 1), center: center, translation: CGVector(dx: center.x - lastCenter.x, dy: center.y - lastCenter.y))]
        case let .threeFinger(start, hasSwiped):
            let center = centroid
            let dx = center.x - start.x
            let dy = center.y - start.y
            guard !hasSwiped, max(abs(dx), abs(dy)) > threeFingerSwipeDistance else { return [] }
            state = .threeFinger(start: start, hasSwiped: true)
            let direction: SwipeDirection = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
            return [.threeFingerSwipe(direction)]
        case let .scrolling(last, lastTime):
            let center = centroid
            let dx = center.x - last.x
            let dy = center.y - last.y
            let interval = time - lastTime
            if interval > 0 {
                // 指先のぶれで速度が乱れないよう、直近の値に寄せつつ平滑化する
                velocity = CGVector(dx: velocity.dx * 0.3 + dx / interval * 0.7, dy: velocity.dy * 0.3 + dy / interval * 0.7)
            }
            state = .scrolling(last: center, lastTime: time)
            return dx == 0 && dy == 0 ? [] : [.scroll(dx: dx, dy: dy)]
        case .idle, .ignoring:
            return []
        }
    }

    public mutating func ended(touch id: Int, at point: CGPoint, time: TimeInterval) -> [Action] {
        guard touches.removeValue(forKey: id) != nil else { return [] }
        switch state {
        case let .pending(touch, start, _, _) where touch == id:
            state = .ignoring
            // 待っている間にスワイプを完了して離した場合は、タップではなくスクロールとして送る
            guard distance(start, point) <= slop else {
                state = .idle
                return [.move(start), .scroll(dx: point.x - start.x, dy: point.y - start.y), .scrollEnded(velocityX: 0, velocityY: 0)]
            }
            return click(.left, at: start) + finishIfAllLifted()
        case let .longPressed(touch, start) where touch == id:
            state = .ignoring
            return click(.right, at: start) + finishIfAllLifted()
        case let .dragging(touch) where touch == id:
            state = .ignoring
            return [.press(.left, isDown: false, at: point)] + finishIfAllLifted()
        case let .twoFingerPending(start, startTime, _):
            state = .ignoring
            let actions = time - startTime <= twoFingerTapMaxDuration ? click(.right, at: start) : []
            return actions + finishIfAllLifted()
        case let .scrolling(_, lastTime):
            guard touches.isEmpty else {
                state = .scrolling(last: centroid, lastTime: lastTime)
                return []
            }
            state = .idle
            let isFlick = time - lastTime <= flickTimeout
            return [.scrollEnded(velocityX: isFlick ? velocity.dx : 0, velocityY: isFlick ? velocity.dy : 0)]
        default:
            return finishIfAllLifted()
        }
    }

    public mutating func cancelled(touch id: Int) -> [Action] {
        guard let point = touches.removeValue(forKey: id) else { return [] }
        var actions: [Action] = []
        switch state {
        case let .dragging(touch) where touch == id:
            actions = [.press(.left, isDown: false, at: point)]
        case .dragging:
            // ドラッグしている指はまだ触れている。ここで判定をやめると、その指を離しても左ボタンを離さず、Mac で押されたまま残る
            return finishIfAllLifted()
        case .scrolling:
            actions = [.scrollEnded(velocityX: 0, velocityY: 0)]
        default:
            break
        }
        state = .ignoring
        return actions + finishIfAllLifted()
    }

    public mutating func longPressTimerFired() -> [Action] {
        guard case let .pending(touch, start, _, _) = state else { return [] }
        state = .longPressed(touch: touch, start: start)
        return [.longPressRecognized]
    }

    /// 3 本目の指が触れたら、それまでの判定をやめて 3 本指のスワイプだけを待つ。
    private mutating func beginThreeFinger() -> [Action] {
        var actions: [Action] = []
        switch state {
        case .pending, .longPressed, .twoFingerPending, .pinching:
            break
        case .scrolling:
            actions = [.scrollEnded(velocityX: 0, velocityY: 0)]
        case .idle, .dragging, .threeFinger, .ignoring:
            return []
        }
        state = .threeFinger(start: centroid, hasSwiped: false)
        return actions
    }

    private mutating func finishIfAllLifted() -> [Action] {
        if touches.isEmpty {
            state = .idle
        }
        return []
    }

    /// 2 本の指の間隔。2 本でなければ 0。
    private var span: CGFloat {
        let points = Array(touches.values)
        guard points.count == 2 else { return 0 }
        return distance(points[0], points[1])
    }

    private var centroid: CGPoint {
        let points = touches.values
        guard !points.isEmpty else { return .zero }
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
