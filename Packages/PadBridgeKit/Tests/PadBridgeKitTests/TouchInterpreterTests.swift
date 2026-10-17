import CoreGraphics
@testable import PadBridgeKit
import Testing

struct TouchInterpreterTests {
    private let a = CGPoint(x: 100, y: 100)

    private func click(_ button: MouseButton, at point: CGPoint) -> [TouchInterpreter.Action] {
        [.move(point), .press(button, isDown: true, at: point), .press(button, isDown: false, at: point)]
    }

    private func presses(in actions: [TouchInterpreter.Action]) -> [TouchInterpreter.Action] {
        actions.filter { if case .press = $0 { true } else { false } }
    }

    @Test func shortTapClicksAtTouchDownPoint() {
        var interpreter = TouchInterpreter()
        #expect(interpreter.began(touch: 1, at: a, time: 0).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 104, y: 103), time: 0.05).isEmpty)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 104, y: 103), time: 0.1) == click(.left, at: a))
    }

    /// 長押しせずに動かしたら、ドラッグではなくスクロールになること。
    @Test func swipeWithoutLongPressScrolls() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.05) == [.move(a), .scroll(dx: 0, dy: 30)])
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 150), time: 0.1) == [.scroll(dx: 0, dy: 20)])
        let end = interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 150), time: 0.12)
        guard case let .scrollEnded(_, velocityY) = end.first else {
            Issue.record("慣性の速さが出ない: \(end)")
            return
        }
        #expect(velocityY > 0)
    }

    @Test func swipeEndedAfterPauseHasNoMomentum() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 150), time: 0.05)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 150), time: 0.6) == [.scrollEnded(velocityX: 0, velocityY: 0)])
    }

    @Test func longPressThenReleaseIsRightClick() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        #expect(interpreter.isWaitingForLongPress)
        #expect(interpreter.longPressTimerFired() == [.longPressRecognized])
        #expect(!interpreter.isWaitingForLongPress)
        #expect(interpreter.ended(touch: 1, at: a, time: 0.8) == click(.right, at: a))
    }

    @Test func longPressThenMoveDragsFromTouchDownPoint() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.longPressTimerFired()
        let b = CGPoint(x: 140, y: 100)
        #expect(interpreter.moved(touch: 1, to: b, time: 0.7) == [.move(a), .press(.left, isDown: true, at: a), .move(b)])
        let c = CGPoint(x: 160, y: 120)
        #expect(interpreter.moved(touch: 1, to: c, time: 0.8) == [.move(c)])
        #expect(interpreter.ended(touch: 1, at: c, time: 1.5) == [.press(.left, isDown: false, at: c)])
    }

    @Test func twoFingerMoveScrollsFromCentroid() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 100), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 200, y: 100), time: 0.02)
        #expect(!interpreter.isWaitingForLongPress)
        let start = CGPoint(x: 150, y: 100)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.05) == [.move(start), .scroll(dx: 0, dy: 15)])
        #expect(interpreter.moved(touch: 2, to: CGPoint(x: 200, y: 130), time: 0.06) == [.scroll(dx: 0, dy: 15)])
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 130), time: 0.5).isEmpty)
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 200, y: 130), time: 0.5) == [.scrollEnded(velocityX: 0, velocityY: 0)])
    }

    /// 1 本指でスクロール中に 2 本目が触れても、重心の飛びをスクロール量にしないこと。
    @Test func addingFingerDuringScrollDoesNotJump() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.05)
        #expect(interpreter.began(touch: 2, at: CGPoint(x: 300, y: 300), time: 0.06).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 140), time: 0.07) == [.scroll(dx: 0, dy: 5)])
    }

    @Test func quickTwoFingerTapIsRightClickAtCentroid() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 100), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 120, y: 140), time: 0.03)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 100), time: 0.15) == click(.right, at: CGPoint(x: 110, y: 120)))
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 120, y: 140), time: 0.16).isEmpty)
    }

    @Test func slowTwoFingerHoldDoesNothing() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 100), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 120, y: 140), time: 0.03)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 100), time: 1.0).isEmpty)
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 120, y: 140), time: 1.0).isEmpty)
    }

    @Test func secondFingerDuringDragIsIgnored() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.longPressTimerFired()
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 150, y: 100), time: 0.6)
        #expect(interpreter.began(touch: 2, at: CGPoint(x: 300, y: 300), time: 0.7).isEmpty)
        #expect(interpreter.moved(touch: 2, to: CGPoint(x: 350, y: 300), time: 0.75).isEmpty)
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 350, y: 300), time: 0.8).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 160, y: 100), time: 0.85) == [.move(CGPoint(x: 160, y: 100))])
        #expect(presses(in: interpreter.ended(touch: 1, at: CGPoint(x: 160, y: 100), time: 0.9)) == [.press(.left, isDown: false, at: CGPoint(x: 160, y: 100))])
    }

    @Test func cancelledDragReleasesButton() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.longPressTimerFired()
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 150, y: 100), time: 0.6)
        #expect(interpreter.cancelled(touch: 1) == [.press(.left, isDown: false, at: CGPoint(x: 150, y: 100))])
        #expect(interpreter.began(touch: 3, at: a, time: 1).isEmpty)
        #expect(interpreter.ended(touch: 3, at: a, time: 1.1) == click(.left, at: a))
    }

    @Test func liftingAfterTwoFingerTapResetsForNextTap() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.began(touch: 2, at: a, time: 0)
        _ = interpreter.ended(touch: 1, at: a, time: 0.1)
        _ = interpreter.ended(touch: 2, at: a, time: 0.1)
        _ = interpreter.began(touch: 3, at: a, time: 1)
        #expect(interpreter.ended(touch: 3, at: a, time: 1.1) == click(.left, at: a))
    }
}

struct ScrollMomentumTests {
    @Test func momentumDeceleratesAndStops() {
        var momentum = ScrollMomentum(velocityX: 0, velocityY: 2000)
        var total: CGFloat = 0
        var previous = CGFloat.infinity
        var frames = 0
        while !momentum.isFinished, frames < 600 {
            let step = momentum.step(interval: 1.0 / 60).dy
            #expect(step > 0 && step < previous)
            previous = step
            total += step
            frames += 1
        }
        #expect(momentum.isFinished)
        // 2000 pt/秒で弾いたら、数百 pt 流れて 2 秒以内に止まる
        #expect(total > 300 && total < 1000)
        #expect(frames < 120)
    }

    @Test func slowFlickDoesNotMove() {
        var momentum = ScrollMomentum(velocityX: 10, velocityY: 10)
        #expect(momentum.isFinished)
        #expect(momentum.step(interval: 1.0 / 60) == .zero)
    }
}
