import CoreGraphics
@testable import PadBridgeKit
import Testing

struct TouchInterpreterTests {
    private let a = CGPoint(x: 100, y: 100)

    private func click(_ button: MouseButton, at point: CGPoint) -> [TouchInterpreter.Action] {
        [.move(point), .press(button, isDown: true, at: point), .press(button, isDown: false, at: point)]
    }

    @Test func shortTapClicksAtTouchDownPoint() {
        var interpreter = TouchInterpreter()
        #expect(interpreter.began(touch: 1, at: a, time: 0).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 104, y: 103)).isEmpty)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 104, y: 103), time: 0.1) == click(.left, at: a))
    }

    @Test func movingBeyondSlopDragsFromTouchDownPoint() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        let b = CGPoint(x: 130, y: 100)
        #expect(interpreter.moved(touch: 1, to: b) == [.move(a), .press(.left, isDown: true, at: a), .move(b)])
        let c = CGPoint(x: 160, y: 120)
        #expect(interpreter.moved(touch: 1, to: c) == [.move(c)])
        #expect(interpreter.ended(touch: 1, at: c, time: 1) == [.press(.left, isDown: false, at: c)])
    }

    @Test func longPressThenReleaseIsRightClick() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        #expect(interpreter.isWaitingForLongPress)
        #expect(interpreter.longPressTimerFired() == [.longPressRecognized])
        #expect(!interpreter.isWaitingForLongPress)
        #expect(interpreter.ended(touch: 1, at: a, time: 0.8) == click(.right, at: a))
    }

    /// 押してから少し待ってドラッグする自然な操作を、右クリックにしないこと。
    @Test func longPressThenMoveIsDragNotRightClick() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.longPressTimerFired()
        let b = CGPoint(x: 140, y: 100)
        #expect(interpreter.moved(touch: 1, to: b) == [.move(a), .press(.left, isDown: true, at: a), .move(b)])
        #expect(interpreter.ended(touch: 1, at: b, time: 1.5) == [.press(.left, isDown: false, at: b)])
    }

    @Test func twoFingerMoveScrollsFromCentroid() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 100), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 200, y: 100), time: 0.02)
        #expect(!interpreter.isWaitingForLongPress)
        let start = CGPoint(x: 150, y: 100)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130)) == [.move(start), .scroll(dx: 0, dy: 15)])
        #expect(interpreter.moved(touch: 2, to: CGPoint(x: 200, y: 130)) == [.scroll(dx: 0, dy: 15)])
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 130), time: 0.5).isEmpty)
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 200, y: 130), time: 0.5).isEmpty)
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
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 150, y: 100))
        #expect(interpreter.began(touch: 2, at: CGPoint(x: 300, y: 300), time: 0.2).isEmpty)
        #expect(interpreter.moved(touch: 2, to: CGPoint(x: 350, y: 300)).isEmpty)
        #expect(interpreter.ended(touch: 2, at: CGPoint(x: 350, y: 300), time: 0.3).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 160, y: 100)) == [.move(CGPoint(x: 160, y: 100))])
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 160, y: 100), time: 0.4) == [.press(.left, isDown: false, at: CGPoint(x: 160, y: 100))])
    }

    @Test func cancelledDragReleasesButton() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 150, y: 100))
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
