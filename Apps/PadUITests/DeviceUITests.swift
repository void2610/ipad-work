import AVFoundation
import XCTest

/// 実機の iPad で、Mac の Host につないだ状態の振る舞いを確かめる。結果の判定は Mac 側 (Host のログと Tools/DeviceProbe) で行う。
final class DeviceUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let screen = app.otherElements["remoteScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "Mac の画面が表示されない")
    }

    /// 裏に回して戻っても、Mac との接続が切れずに映像が戻ること。
    @MainActor
    func testStaysConnectedInBackground() throws {
        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        XCTAssertTrue(app.otherElements["remoteScreen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '再接続中'")).firstMatch.exists, "再接続になっている")
        sleep(3)
    }

    /// 1 本指で払うとスクロールになり、長押ししてから動かすとドラッグになること。判定は Mac 側の Host のログで行う。
    @MainActor
    func testSwipeScrollsAndLongPressDrags() throws {
        let screen = app.otherElements["remoteScreen"]
        sleep(2)
        screen.swipeUp()
        sleep(2)
        let from = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let to = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        from.press(forDuration: 1.0, thenDragTo: to)
        sleep(2)
    }

    /// Typeless ボタンのタップで Mac の Typeless が聞き取りを始め、iPad のスピーカーで話した言葉が、もう一度のタップで Mac に入力されること。
    /// Mac 自身のスピーカーの音はエコーキャンセルで消されるので、話し手は iPad にしている。判定は Mac 側の Tools/DeviceProbe が行う。
    @MainActor
    func testTypelessTranscribesSpeech() throws {
        let button = app.buttons["Typeless"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        sleep(2)
        button.tap()
        sleep(1)
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "これは音声入力のテストです")
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        synthesizer.speak(utterance)
        // 話し始めるまで少しかかるので、1 秒待ってから話し終わりを見る
        RunLoop.current.run(until: .now + 1)
        let deadline = Date.now.addingTimeInterval(10)
        while synthesizer.isSpeaking, Date.now < deadline {
            RunLoop.current.run(until: .now + 0.2)
        }
        sleep(1)
        button.tap()
        sleep(8)
    }
}
