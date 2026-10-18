import CoreGraphics
import Foundation
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
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.1) == [.move(a), .scroll(dx: 0, dy: 30)])
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 150), time: 0.15) == [.scroll(dx: 0, dy: 20)])
        let end = interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 150), time: 0.17)
        guard case let .scrollEnded(_, velocityY) = end.first else {
            Issue.record("慣性の速さが出ない: \(end)")
            return
        }
        #expect(velocityY > 0)
    }

    /// 3 本指で払うとき、1 本目が先に動いても、他の指を待つ間はスクロールを送らないこと。
    @Test func firstFingerMovingBeforeOthersLandDoesNotScroll() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 300), time: 0)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 80, y: 300), time: 0.03).isEmpty)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 150, y: 300), time: 0.04)
        _ = interpreter.began(touch: 3, at: CGPoint(x: 200, y: 300), time: 0.05)
        let actions = [(1, CGFloat(20)), (2, 70), (3, 120)].flatMap { id, x in
            interpreter.moved(touch: id, to: CGPoint(x: x, y: 300), time: 0.12)
        }
        #expect(actions == [.threeFingerSwipe(.left)])
    }

    /// 画面の下端から上へ払うと、スクロールではなく Dock を出す操作になること。
    @Test func swipeUpFromBottomEdgeShowsDock() {
        var interpreter = TouchInterpreter()
        interpreter.bottomEdge = 800
        _ = interpreter.began(touch: 1, at: CGPoint(x: 400, y: 790), time: 0)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 402, y: 775), time: 0.03).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 405, y: 750), time: 0.06) == [.bottomEdgeSwipe])
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 405, y: 600), time: 0.1).isEmpty)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 405, y: 600), time: 0.12).isEmpty)
    }

    /// 下端の近くでも、タップと横への払いはいつもどおりクリックとスクロールになること。
    @Test func tapAndSideSwipeNearBottomEdgeStayNormal() {
        var interpreter = TouchInterpreter()
        interpreter.bottomEdge = 800
        let point = CGPoint(x: 400, y: 790)
        _ = interpreter.began(touch: 1, at: point, time: 0)
        #expect(interpreter.ended(touch: 1, at: point, time: 0.1) == click(.left, at: point))
        _ = interpreter.began(touch: 2, at: point, time: 1)
        #expect(interpreter.moved(touch: 2, to: CGPoint(x: 440, y: 785), time: 1.1) == [.move(point), .scroll(dx: 40, dy: -5)])
    }

    /// 下端から離れたところで上へ払ったら、いつもどおりスクロールになること。
    @Test func swipeUpAwayFromBottomEdgeScrolls() {
        var interpreter = TouchInterpreter()
        interpreter.bottomEdge = 800
        let start = CGPoint(x: 400, y: 600)
        _ = interpreter.began(touch: 1, at: start, time: 0)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 400, y: 560), time: 0.1) == [.move(start), .scroll(dx: 0, dy: -40)])
    }

    @Test func movementDuringGraceIsKeptInFirstScroll() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.03).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 150), time: 0.1) == [.move(a), .scroll(dx: 0, dy: 50)])
    }

    @Test func quickFlickWithinGraceStillScrolls() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 160), time: 0.04)
        #expect(interpreter.ended(touch: 1, at: CGPoint(x: 100, y: 160), time: 0.05) == [.move(a), .scroll(dx: 0, dy: 60), .scrollEnded(velocityX: 0, velocityY: 0)])
    }

    @Test func swipeEndedAfterPauseHasNoMomentum() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 150), time: 0.1)
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
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 130), time: 0.1)
        #expect(interpreter.began(touch: 2, at: CGPoint(x: 300, y: 300), time: 0.11).isEmpty)
        #expect(interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 140), time: 0.12) == [.scroll(dx: 0, dy: 5)])
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

    /// ドラッグ中に触れた別の指だけが取り消されても (手のひらや画面の端のシステムのジェスチャー)、ドラッグしている指を離せば左ボタンを離す。
    @Test func cancellingOtherFingerKeepsDragReleasable() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: a, time: 0)
        _ = interpreter.longPressTimerFired()
        let b = CGPoint(x: 150, y: 100)
        _ = interpreter.moved(touch: 1, to: b, time: 0.6)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 400, y: 400), time: 0.7)
        #expect(interpreter.cancelled(touch: 2) == [])
        let c = CGPoint(x: 170, y: 110)
        #expect(interpreter.moved(touch: 1, to: c, time: 0.8) == [.move(c)])
        #expect(interpreter.ended(touch: 1, at: c, time: 0.9) == [.press(.left, isDown: false, at: c)])
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

struct ThreeFingerSwipeTests {
    private func threeFingers(_ interpreter: inout TouchInterpreter) {
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 300), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 150, y: 300), time: 0.01)
        _ = interpreter.began(touch: 3, at: CGPoint(x: 200, y: 300), time: 0.02)
    }

    private func moveAll(_ interpreter: inout TouchInterpreter, dx: CGFloat, dy: CGFloat, time: TimeInterval) -> [TouchInterpreter.Action] {
        [(1, 100), (2, 150), (3, 200)].flatMap { id, x in
            interpreter.moved(touch: id, to: CGPoint(x: x + dx, y: 300 + dy), time: time)
        }
    }

    @Test(arguments: [
        (CGFloat(-80), CGFloat(5), TouchInterpreter.SwipeDirection.left),
        (80, -5, .right),
        (5, -80, .up),
        (-5, 80, .down),
    ])
    func swipeFiresOnceInDominantDirection(dx: CGFloat, dy: CGFloat, direction: TouchInterpreter.SwipeDirection) {
        var interpreter = TouchInterpreter()
        threeFingers(&interpreter)
        #expect(moveAll(&interpreter, dx: dx, dy: dy, time: 0.1) == [.threeFingerSwipe(direction)])
        #expect(moveAll(&interpreter, dx: dx * 2, dy: dy * 2, time: 0.2).isEmpty)
        for id in 1 ... 3 {
            #expect(interpreter.ended(touch: id, at: .zero, time: 0.3).isEmpty)
        }
    }

    @Test func smallThreeFingerMoveDoesNothing() {
        var interpreter = TouchInterpreter()
        threeFingers(&interpreter)
        #expect(moveAll(&interpreter, dx: 20, dy: 0, time: 0.1).isEmpty)
        for id in 1 ... 3 {
            #expect(interpreter.ended(touch: id, at: .zero, time: 0.3).isEmpty)
        }
    }

    @Test func thirdFingerDuringScrollEndsScrollAndWaitsForSwipe() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 300), time: 0)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 340), time: 0.1)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 150, y: 300), time: 0.11)
        #expect(interpreter.began(touch: 3, at: CGPoint(x: 200, y: 300), time: 0.12) == [.scrollEnded(velocityX: 0, velocityY: 0)])
    }

    /// 2 本指でしばらくスクロールしてから親指が触れても、3 本指の払いにせずスクロールを続ける。
    @Test func lateThirdFingerDuringTwoFingerScrollKeepsScrolling() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 100, y: 300), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 150, y: 300), time: 0.01)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 100, y: 330), time: 0.1)
        _ = interpreter.moved(touch: 2, to: CGPoint(x: 150, y: 330), time: 0.1)
        #expect(interpreter.began(touch: 3, at: CGPoint(x: 400, y: 600), time: 0.6).isEmpty)
        // 3 本で動かしても払いにならず、重心の動いた分だけスクロールする
        let actions = [(1, CGFloat(100)), (2, 150), (3, 400)].flatMap { id, x in
            interpreter.moved(touch: id, to: CGPoint(x: x, y: (id == 3 ? 600 : 330) - 90), time: 0.7)
        }
        #expect(!actions.contains { if case .threeFingerSwipe = $0 { true } else { false } })
        #expect(actions.contains { if case .scroll = $0 { true } else { false } })
    }

    /// 左へ払うと右隣のスペースへ移る、トラックパッドと同じ向きにすること。
    @Test func directionsMapToTrackpadActions() {
        #expect(DesktopAction(swipe: .left) == .switchSpace(toRight: true))
        #expect(DesktopAction(swipe: .right) == .switchSpace(toRight: false))
        #expect(DesktopAction(swipe: .up) == .controlArrow(usage: KeyboardMapping.ArrowUsage.up))
        #expect(DesktopAction(swipe: .down) == .controlArrow(usage: KeyboardMapping.ArrowUsage.down))
    }
}

struct PinchTests {
    /// 2 本指を広げると拡大になり、スクロールは送らないこと。
    @Test func spreadingTwoFingersZooms() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 400, y: 300), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 500, y: 300), time: 0.01)
        _ = interpreter.moved(touch: 1, to: CGPoint(x: 380, y: 300), time: 0.05)
        let actions = interpreter.moved(touch: 2, to: CGPoint(x: 520, y: 300), time: 0.05)
        guard case let .zoom(scale, center, _) = actions.first else {
            Issue.record("拡大にならない: \(actions)")
            return
        }
        #expect(abs(scale - 1.4) < 0.001)
        #expect(center == CGPoint(x: 450, y: 300))
        let next = interpreter.moved(touch: 2, to: CGPoint(x: 590, y: 300), time: 0.1)
        guard case let .zoom(nextScale, _, translation) = next.first else {
            Issue.record("続けて広げても拡大にならない: \(next)")
            return
        }
        #expect(abs(nextScale - 1.5) < 0.001)
        #expect(translation.dx == 35)
    }

    /// 間隔を保ったまま 2 本指で払うと、これまでどおりスクロールになること。
    @Test func movingTwoFingersTogetherScrolls() {
        var interpreter = TouchInterpreter()
        _ = interpreter.began(touch: 1, at: CGPoint(x: 400, y: 300), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 500, y: 300), time: 0.01)
        let actions = interpreter.moved(touch: 1, to: CGPoint(x: 400, y: 340), time: 0.05)
            + interpreter.moved(touch: 2, to: CGPoint(x: 500, y: 340), time: 0.05)
        let scrolled = actions.reduce(CGFloat(0)) { total, action in
            if case let .scroll(_, dy) = action { total + dy } else { total }
        }
        #expect(scrolled == 40)
        #expect(!actions.contains { if case .zoom = $0 { true } else { false } })
    }

    /// 2 本指で軽く触れて離すだけなら、これまでどおり 2 本の指の中ほどで右クリックになること。
    @Test func twoFingerTapStillRightClicks() {
        var interpreter = TouchInterpreter()
        let middle = CGPoint(x: 450, y: 300)
        _ = interpreter.began(touch: 1, at: CGPoint(x: 400, y: 300), time: 0)
        _ = interpreter.began(touch: 2, at: CGPoint(x: 500, y: 300), time: 0.01)
        let actions = interpreter.ended(touch: 1, at: CGPoint(x: 400, y: 300), time: 0.1)
        #expect(actions == [.move(middle), .press(.right, isDown: true, at: middle), .press(.right, isDown: false, at: middle)])
    }
}

struct ScreenZoomTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let fitted = CGRect(x: 0, y: 75, width: 1000, height: 650)

    @Test func unzoomedIsFitted() {
        #expect(ScreenZoom().rect(fitted: fitted, in: area) == fitted)
    }

    /// 指を大きく開いた位置から始めたピンチは 1 回ごとの倍率が小さい。それでも、少しずつ広げ続ければ拡大が始まる。
    @Test func slowWidePinchStartsZooming() {
        var zoom = ScreenZoom()
        for _ in 0 ..< 10 {
            zoom.apply(scale: 1.02, center: CGPoint(x: 500, y: 400), translation: .zero, fitted: fitted, area: area)
        }
        #expect(zoom.isZoomed)
        #expect(abs(zoom.scale - pow(1.02, 10)) < 0.001)
    }

    /// 少しだけ広げた途中で、指を動かすだけの更新 (倍率 1) が来ても等倍に戻さない。
    @Test func panDuringSmallZoomKeepsScale() {
        var zoom = ScreenZoom()
        zoom.apply(scale: 1.02, center: CGPoint(x: 500, y: 400), translation: .zero, fitted: fitted, area: area)
        zoom.apply(scale: 1, center: CGPoint(x: 500, y: 400), translation: CGVector(dx: 5, dy: 0), fitted: fitted, area: area)
        #expect(abs(zoom.scale - 1.02) < 0.001)
    }

    /// 縮めて等倍の近くまで戻したときは、ぴったり等倍に戻す。
    @Test func shrinkingNearOneSnapsBack() {
        var zoom = ScreenZoom()
        zoom.apply(scale: 1.5, center: CGPoint(x: 500, y: 400), translation: .zero, fitted: fitted, area: area)
        zoom.apply(scale: 1.03 / 1.5, center: CGPoint(x: 500, y: 400), translation: .zero, fitted: fitted, area: area)
        #expect(zoom == ScreenZoom())
    }

    /// 指の中心の下にある映像の位置が、拡大しても動かないこと。
    @Test func zoomKeepsPointUnderFingers() {
        var zoom = ScreenZoom()
        let center = CGPoint(x: 300, y: 400)
        let before = fitted
        let normalizedX = (center.x - before.minX) / before.width
        zoom.apply(scale: 2, center: center, translation: .zero, fitted: fitted, area: area)
        let after = zoom.rect(fitted: fitted, in: area)
        #expect(after.width == 2000)
        #expect(abs(after.minX + normalizedX * after.width - center.x) < 0.001)
    }

    /// 端に余白が出るほど外へ寄せても、画面の端で止まること。
    @Test func zoomedRectStaysOverArea() {
        var zoom = ScreenZoom()
        zoom.apply(scale: 2, center: CGPoint(x: 500, y: 400), translation: CGVector(dx: 5000, dy: 5000), fitted: fitted, area: area)
        let rect = zoom.rect(fitted: fitted, in: area)
        #expect(rect.minX == 0)
        #expect(rect.minY == 0)
        #expect(rect.maxX >= area.maxX)
    }

    /// 縮めてほぼ等倍に戻したら、ぴったり元に戻ること。
    @Test func pinchingBackResets() {
        var zoom = ScreenZoom()
        zoom.apply(scale: 2, center: CGPoint(x: 200, y: 200), translation: .zero, fitted: fitted, area: area)
        zoom.apply(scale: 0.51, center: CGPoint(x: 200, y: 200), translation: .zero, fitted: fitted, area: area)
        #expect(zoom == ScreenZoom())
    }

    @Test func scaleIsLimited() {
        var zoom = ScreenZoom()
        zoom.apply(scale: 50, center: CGPoint(x: 500, y: 400), translation: .zero, fitted: fitted, area: area)
        #expect(zoom.scale == ScreenZoom.maximumScale)
    }
}
