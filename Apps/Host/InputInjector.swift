import AppKit
import CoreGraphics
import Foundation
import PadBridgeKit

/// iPad から届いた操作を、CGEvent として Mac に流し込む。HostServer の入力キューの上でだけ使う。
nonisolated final class InputInjector: @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var clickCounter: ClickCounter
    private var currentClickCount = 1
    private var pressedButtons: Set<MouseButton> = []
    private var pressedKeys: Set<UInt16> = []
    private var scrollRemainder = CGPoint.zero
    private var location = CGPoint.zero
    // iPad に映している画面。タッチの位置はこの画面の上の割合で届く
    private var displayID: CGDirectDisplayID?
    private var typeless = TypelessToggle()
    private var heldModifiers = HeldModifiers()
    private let queue: DispatchQueue
    private let keyRepeatDelay: TimeInterval
    private let keyRepeatInterval: TimeInterval
    private var keyRepeat = KeyRepeat()
    private var keyRepeatTimer: DispatchSourceTimer?

    /// `queue` は HostServer の入力キュー。押したままのキーの繰り返しもこのキューで送る。
    init(queue: DispatchQueue, doubleClickInterval: TimeInterval, keyRepeatDelay: TimeInterval, keyRepeatInterval: TimeInterval) {
        self.queue = queue
        // iPad の指は狙った位置から数ポイントずれるので、Mac のマウスより判定を緩める
        clickCounter = ClickCounter(interval: doubleClickInterval, maxDistance: 16)
        self.keyRepeatDelay = keyRepeatDelay
        self.keyRepeatInterval = keyRepeatInterval
    }

    func handle(_ message: ControlMessage) {
        switch message {
        case let .mouseMove(point):
            move(to: screenPoint(point))
        case let .mouseButton(button, isDown, point):
            press(button, isDown: isDown, at: screenPoint(point))
        case let .scroll(dx, dy):
            scroll(dx: dx, dy: dy)
        case let .key(usage, isDown, modifiers):
            key(usage: usage, isDown: isDown, modifiers: modifiers)
        case let .voiceInput(isActive):
            setVoiceInput(isActive)
        case let .desktopSwipe(direction):
            perform(DesktopAction(swipe: direction))
        default:
            break
        }
    }

    func setDisplay(_ displayID: CGDirectDisplayID?) {
        self.displayID = displayID
    }

    /// 映す画面を選び直したときに、ポインタをその画面の中央へ動かす。
    /// Mission Control など、画面ごとの操作スペースではポインタのある画面に効く操作を、映している画面に効かせるため。
    func moveToDisplayCenter() {
        move(to: screenPoint(NormalizedPoint(x: 0.5, y: 0.5)))
    }

    /// Typeless のマイクが動き出したり止まったりしたときに呼ぶ。
    func typelessRecordingChanged(_ isRecording: Bool) {
        typeless.observe(isRecording: isRecording)
    }

    /// 接続が切れたときに、押しっぱなしのボタンやキーが残らないよう全部離す。
    func releaseAll() {
        if typeless.isStartedByPad {
            setVoiceInput(false)
        }
        stopKeyRepeat()
        for button in pressedButtons {
            press(button, isDown: false, at: location)
        }
        for keyCode in pressedKeys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { continue }
            if KeyboardMapping.isModifier(macVirtualKeyCode: keyCode) {
                event.type = .flagsChanged
            }
            event.flags = CGEventFlags(rawValue: 0x100)
            event.post(tap: .cghidEventTap)
        }
        pressedKeys.removeAll()
        heldModifiers.removeAll()
    }

    /// Typeless の音声入力を始める (true) / 終える (false)。
    /// Typeless の音声入力のショートカットは押すたびに開始と完了が切り替わり、押し続けると使い方の案内が出るだけなので、短く 1 回押す。
    private func setVoiceInput(_ isActive: Bool) {
        guard typeless.shouldPress(toBecome: isActive, isRecording: TypelessMonitor.isRecording(), at: ProcessInfo.processInfo.systemUptime) else { return }
        if isActive {
            Self.launchTypelessIfNeeded()
        }
        // Typeless 側でショートカットを変えても追従できるよう、押すたびに設定を読み直す
        let shortcut = Self.typelessPushToTalk()
        post(shortcut.events(isDown: true))
        Thread.sleep(forTimeInterval: 0.05)
        post(shortcut.events(isDown: false))
    }

    /// Typeless が動いていなければ起動する。動いていないとショートカットを押しても何も起きないため。
    /// 起動してからショートカットを待ち受けるまで少しかかるので、待ち受け始めるのを待つ (入力のキューの上なので、待つ間ほかの操作は後回しになる)。
    private static func launchTypelessIfNeeded() {
        guard !TypelessApp.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TypelessApp.bundleIdentifier) else { return }
        let launched = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in launched.signal() }
        _ = launched.wait(timeout: .now() + 10)
        let deadline = Date.now + 10
        while !TypelessApp.isListeningForShortcut(), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func post(_ events: [TypelessShortcut.KeyEvent]) {
        for keyEvent in events {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyEvent.keyCode, keyDown: keyEvent.isDown) else { continue }
            if keyEvent.isModifier {
                event.type = .flagsChanged
            }
            event.flags = CGEventFlags(rawValue: keyEvent.flags)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Typeless の設定ファイルを読むだけで、書き換えはしない。読めなければ Typeless の既定 (LeftCtrl+Fn) を使う。
    private static func typelessPushToTalk() -> TypelessShortcut {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Typeless/app-settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shortcuts = settings["keyboardShortcut"] as? [String: Any],
              let text = shortcuts["pushToTalk"] as? String,
              let shortcut = TypelessShortcut(text)
        else { return .typelessDefault }
        return shortcut
    }

    private var displayBounds: CGRect {
        let bounds = displayID.map(CGDisplayBounds) ?? .null
        // 画面を外した直後で、Host がまだ映す画面を替えていない間は大きさ 0 が返る。メインディスプレイの上として扱う
        return bounds.isEmpty ? CGDisplayBounds(CGMainDisplayID()) : bounds
    }

    private func screenPoint(_ point: NormalizedPoint) -> CGPoint {
        let bounds = displayBounds
        // 右端と下端 (割合 1) は隣の画面の端にあたるので、映している画面の内側に収める
        return CGPoint(x: min(bounds.minX + point.x * bounds.width, bounds.maxX - 1), y: min(bounds.minY + point.y * bounds.height, bounds.maxY - 1))
    }

    private func move(to point: CGPoint) {
        location = point
        if pressedButtons.contains(.left) {
            postMouse(.leftMouseDragged, button: .left, clickCount: currentClickCount)
        } else if pressedButtons.contains(.right) {
            postMouse(.rightMouseDragged, button: .right, clickCount: currentClickCount)
        } else {
            postMouse(.mouseMoved, button: .left, clickCount: nil)
        }
    }

    private func press(_ button: MouseButton, isDown: Bool, at point: CGPoint) {
        location = point
        if isDown {
            currentClickCount = clickCounter.registerDown(button: button, x: point.x, y: point.y, time: ProcessInfo.processInfo.systemUptime)
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }
        switch button {
        case .left: postMouse(isDown ? .leftMouseDown : .leftMouseUp, button: .left, clickCount: currentClickCount)
        case .right: postMouse(isDown ? .rightMouseDown : .rightMouseUp, button: .right, clickCount: currentClickCount)
        }
    }

    private func scroll(dx: Double, dy: Double) {
        let bounds = displayBounds
        // 端数を持ち越さないと、ゆっくり動かしたときに 1 ピクセル未満の移動が全部消える
        scrollRemainder.x += dx * bounds.width
        scrollRemainder.y += dy * bounds.height
        let wheelX = Int32(scrollRemainder.x.rounded(.towardZero))
        let wheelY = Int32(scrollRemainder.y.rounded(.towardZero))
        guard wheelX != 0 || wheelY != 0 else { return }
        scrollRemainder.x -= CGFloat(wheelX)
        scrollRemainder.y -= CGFloat(wheelY)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0)
        // ⌘ を押しながらのスクロールで拡大するアプリがあるので、押されている修飾キーを載せる
        event?.flags = CGEventFlags(rawValue: heldModifiers.mouseEventFlags)
        event?.post(tap: .cghidEventTap)
    }

    private func key(usage: Int, isDown: Bool, modifiers: KeyModifiers) {
        guard let keyEvent = heldModifiers.keyEvent(usage: usage, isDown: isDown, modifiers: modifiers) else { return }
        heldModifiers.apply(keyEvent)
        if isDown {
            pressedKeys.insert(keyEvent.keyCode)
        } else {
            pressedKeys.remove(keyEvent.keyCode)
        }
        post(keyEvent)
        if keyRepeat.apply(keyEvent, heldModifiers: heldModifiers.modifiers) {
            startKeyRepeat()
        } else if keyRepeat.key == nil {
            stopKeyRepeat()
        }
    }

    private func startKeyRepeat() {
        keyRepeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Mac のキーボード設定の「リピート入力認識までの時間」と「キーのリピート」に合わせる
        timer.schedule(deadline: .now() + keyRepeatDelay, repeating: keyRepeatInterval)
        timer.setEventHandler { [weak self] in self?.postKeyRepeat() }
        timer.resume()
        keyRepeatTimer = timer
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.cancel()
        keyRepeatTimer = nil
        keyRepeat.stop()
    }

    private func postKeyRepeat() {
        guard let key = keyRepeat.key, let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true) else {
            stopKeyRepeat()
            return
        }
        event.flags = CGEventFlags(rawValue: key.flags)
        // 実際のキーボードの繰り返しと同じ印を付け、アプリが押し続けによる入力として扱えるようにする
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func perform(_ action: DesktopAction) {
        switch action {
        case let .switchSpace(toRight):
            SpaceSwitcher.switchSpace(toRight: toRight)
        case let .controlArrow(usage):
            for case let .key(usage, isDown, modifiers) in RemoteKeys.controlArrow(usage: usage) {
                key(usage: usage, isDown: isDown, modifiers: modifiers)
            }
        }
    }

    private func post(_ keyEvent: MacKeyEvent) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyEvent.keyCode, keyDown: keyEvent.isDown) else { return }
        if keyEvent.isFlagsChanged {
            event.type = .flagsChanged
        }
        event.flags = CGEventFlags(rawValue: keyEvent.flags)
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, clickCount: Int?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        if let clickCount {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        // ⌘クリックや ⇧クリックになるよう、押されている修飾キーを載せる
        event.flags = CGEventFlags(rawValue: heldModifiers.mouseEventFlags)
        event.post(tap: .cghidEventTap)
    }
}
