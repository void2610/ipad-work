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
    private var isVoiceInputActive = false

    init(doubleClickInterval: TimeInterval) {
        // iPad の指は狙った位置から数ポイントずれるので、Mac のマウスより判定を緩める
        clickCounter = ClickCounter(interval: doubleClickInterval, maxDistance: 16)
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
        default:
            break
        }
    }

    /// 接続が切れたときに、押しっぱなしのボタンやキーが残らないよう全部離す。
    func releaseAll() {
        setVoiceInput(false)
        for button in pressedButtons {
            press(button, isDown: false, at: location)
        }
        for keyCode in pressedKeys {
            postKey(keyCode, isDown: false, flags: [])
        }
        pressedKeys.removeAll()
    }

    /// Typeless の音声入力を始める (true) / 終える (false)。
    /// Typeless の音声入力のショートカットは押すたびに開始と完了が切り替わり、押し続けると使い方の案内が出るだけなので、短く 1 回押す。
    private func setVoiceInput(_ isActive: Bool) {
        guard isVoiceInputActive != isActive else { return }
        isVoiceInputActive = isActive
        // Typeless 側でショートカットを変えても追従できるよう、押すたびに設定を読み直す
        let shortcut = Self.typelessPushToTalk()
        post(shortcut.events(isDown: true))
        Thread.sleep(forTimeInterval: 0.05)
        post(shortcut.events(isDown: false))
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

    private func screenPoint(_ point: NormalizedPoint) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.minX + point.x * bounds.width, y: bounds.minY + point.y * bounds.height)
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
        let bounds = CGDisplayBounds(CGMainDisplayID())
        // 端数を持ち越さないと、ゆっくり動かしたときに 1 ピクセル未満の移動が全部消える
        scrollRemainder.x += dx * bounds.width
        scrollRemainder.y += dy * bounds.height
        let wheelX = Int32(scrollRemainder.x.rounded(.towardZero))
        let wheelY = Int32(scrollRemainder.y.rounded(.towardZero))
        guard wheelX != 0 || wheelY != 0 else { return }
        scrollRemainder.x -= CGFloat(wheelX)
        scrollRemainder.y -= CGFloat(wheelY)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func key(usage: Int, isDown: Bool, modifiers: KeyModifiers) {
        guard let keyCode = KeyboardMapping.macVirtualKeyCode(forHIDUsage: usage) else { return }
        if isDown {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
        postKey(keyCode, isDown: isDown, flags: CGEventFlags(rawValue: KeyboardMapping.eventFlags(modifiers: modifiers, macVirtualKeyCode: keyCode)))
    }

    private func postKey(_ keyCode: UInt16, isDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
        if KeyboardMapping.isModifier(macVirtualKeyCode: keyCode) {
            // 修飾キー単体はキー押下ではなく修飾状態の変化として届けないと、アプリが Command などを認識しない
            event.type = .flagsChanged
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, clickCount: Int?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        if let clickCount {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }
}
