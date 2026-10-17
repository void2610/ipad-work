@testable import PadBridgeKit
import Testing

struct KeyboardMappingTests {
    @Test(arguments: [
        (0x04, UInt16(0x00)), // A
        (0x1D, 0x06), // Z
        (0x27, 0x1D), // 0
        (0x28, 0x24), // Return
        (0x2A, 0x33), // Backspace
        (0x50, 0x7B), // ←
        (0x91, 0x66), // 英数
        (0xE3, 0x37), // 左 Command
    ])
    func knownUsagesMap(usage: Int, keyCode: UInt16) {
        #expect(KeyboardMapping.macVirtualKeyCode(forHIDUsage: usage) == keyCode)
    }

    @Test func unknownUsageIsNil() {
        #expect(KeyboardMapping.macVirtualKeyCode(forHIDUsage: 0xFF) == nil)
    }

    /// Mission Control などのショートカットが反応するよう、矢印キーには Fn とテンキーのビットを付けること。
    @Test func arrowKeysCarryFunctionAndKeypadFlags() {
        #expect(KeyboardMapping.eventFlags(modifiers: [.control], macVirtualKeyCode: 0x7E) == 0x40101 | 0x200000 | 0x800000)
        #expect(KeyboardMapping.eventFlags(modifiers: [], macVirtualKeyCode: 0x00) == 0x100)
        #expect(KeyboardMapping.eventFlags(modifiers: [.command, .shift], macVirtualKeyCode: 0x73) == 0x100108 | 0x20002 | 0x800000)
    }

    @Test func modifiersAreDetected() {
        #expect(KeyboardMapping.isModifier(macVirtualKeyCode: 0x37))
        #expect(!KeyboardMapping.isModifier(macVirtualKeyCode: 0x24))
    }
}

struct ClickCounterTests {
    @Test func quickSecondClickIsDoubleClick() {
        var counter = ClickCounter(interval: 0.5, maxDistance: 10)
        #expect(counter.registerDown(button: .left, x: 100, y: 100, time: 0) == 1)
        #expect(counter.registerDown(button: .left, x: 104, y: 103, time: 0.3) == 2)
        #expect(counter.registerDown(button: .left, x: 104, y: 103, time: 0.6) == 3)
    }

    @Test func slowOrDistantOrOtherButtonResets() {
        var counter = ClickCounter(interval: 0.5, maxDistance: 10)
        _ = counter.registerDown(button: .left, x: 0, y: 0, time: 0)
        #expect(counter.registerDown(button: .left, x: 0, y: 0, time: 0.8) == 1)
        #expect(counter.registerDown(button: .left, x: 50, y: 0, time: 0.9) == 1)
        #expect(counter.registerDown(button: .right, x: 50, y: 0, time: 1.0) == 1)
    }
}

struct TypelessShortcutTests {
    /// 実際のキーボードと同じく、左 Control を示す 0x1 と、実入力を示す 0x100 を載せること。
    @Test func defaultPushToTalkPressesLeftCtrlThenFn() {
        let shortcut = TypelessShortcut("LeftCtrl+Fn")!
        #expect(shortcut.events(isDown: true) == [
            .init(keyCode: 0x3B, isDown: true, isModifier: true, flags: 0x40101),
            .init(keyCode: 0x3F, isDown: true, isModifier: true, flags: 0x840101),
        ])
        #expect(shortcut.events(isDown: false) == [
            .init(keyCode: 0x3F, isDown: false, isModifier: true, flags: 0x40101),
            .init(keyCode: 0x3B, isDown: false, isModifier: true, flags: 0x100),
        ])
    }

    @Test func rightCtrlUsesRightDeviceBit() {
        #expect(TypelessShortcut("RightCtrl")!.events(isDown: true).first?.flags == 0x42100)
    }

    @Test func letterKeyIsPressedWithModifiers() {
        let shortcut = TypelessShortcut("Ctrl+Cmd+V")!
        let down = shortcut.events(isDown: true)
        #expect(down.last == .init(keyCode: 0x09, isDown: true, isModifier: false, flags: 0x40001 | 0x100008 | 0x100))
    }

    @Test(arguments: ["", "Ctrl+Unknown", "Hyper"])
    func unknownShortcutIsRejected(text: String) {
        #expect(TypelessShortcut(text) == nil)
    }
}

struct TypelessToggleTests {
    @Test func pressesOnlyWhenTypelessIsInTheOtherState() {
        var toggle = TypelessToggle()
        let pressedToStart = toggle.shouldPress(toBecome: true, isRecording: false, at: 0)
        #expect(pressedToStart)
        toggle.observe(isRecording: true)
        let pressedAgain = toggle.shouldPress(toBecome: true, isRecording: true, at: 2)
        #expect(!pressedAgain)
        let pressedToStop = toggle.shouldPress(toBecome: false, isRecording: true, at: 3)
        #expect(pressedToStop)
    }

    /// Typeless が自分で聞き取りを終えたあとに「完了」が来ても押さない。押すと逆に聞き取りが始まってしまう。
    @Test func doesNotPressWhenTypelessAlreadyStopped() {
        var toggle = TypelessToggle()
        _ = toggle.shouldPress(toBecome: true, isRecording: false, at: 0)
        toggle.observe(isRecording: true)
        toggle.observe(isRecording: false)
        let pressed = toggle.shouldPress(toBecome: false, isRecording: false, at: 10)
        #expect(!pressed)
    }

    /// 押した直後はまだマイクが動いていないので、すぐの「完了」は押した結果を待たずに押す。
    @Test func treatsPressAsAppliedUntilTypelessCatchesUp() {
        var toggle = TypelessToggle()
        _ = toggle.shouldPress(toBecome: true, isRecording: false, at: 0)
        let pressed = toggle.shouldPress(toBecome: false, isRecording: false, at: 0.1)
        #expect(pressed)
    }

    /// Typeless が押されたことに反応しなかったら、猶予のあとは実際の状態に戻って押し直せる。
    @Test func fallsBackToActualStateWhenPressWasIgnored() {
        var toggle = TypelessToggle()
        _ = toggle.shouldPress(toBecome: true, isRecording: false, at: 0)
        let pressed = toggle.shouldPress(toBecome: true, isRecording: false, at: TypelessToggle.settleTime + 0.1)
        #expect(pressed)
    }

    /// Mac で自分で始めた聞き取りは、iPad が始めさせたものとして扱わない。
    @Test func remembersOnlyListeningStartedByPad() {
        var toggle = TypelessToggle()
        #expect(!toggle.isStartedByPad)
        _ = toggle.shouldPress(toBecome: true, isRecording: false, at: 0)
        #expect(toggle.isStartedByPad)
        toggle.observe(isRecording: true)
        toggle.observe(isRecording: false)
        #expect(!toggle.isStartedByPad)
    }
}

struct KeyRepeatTests {
    private func event(_ usage: Int, _ isDown: Bool, _ modifiers: KeyModifiers = []) -> MacKeyEvent {
        MacKeyEvent(usage: usage, isDown: isDown, modifiers: modifiers)!
    }

    @Test func heldKeyRepeatsUntilReleased() {
        var keyRepeat = KeyRepeat()
        let startedOnDown = keyRepeat.apply(event(0x2A, true), heldModifiers: [])
        #expect(startedOnDown)
        #expect(keyRepeat.key?.keyCode == 0x33)
        let startedOnUp = keyRepeat.apply(event(0x2A, false), heldModifiers: [])
        #expect(!startedOnUp)
        #expect(keyRepeat.key == nil)
    }

    /// 2 つ目のキーを押したらそちらを繰り返し、先に押したキーを離しても止めない。
    @Test func onlyLatestKeyRepeats() {
        var keyRepeat = KeyRepeat()
        _ = keyRepeat.apply(event(0x04, true), heldModifiers: [])
        let startedSecond = keyRepeat.apply(event(0x05, true), heldModifiers: [])
        #expect(startedSecond)
        _ = keyRepeat.apply(event(0x04, false), heldModifiers: [])
        #expect(keyRepeat.key?.keyCode == 0x0B)
    }

    @Test func modifiersAloneDoNotRepeat() {
        var keyRepeat = KeyRepeat()
        let started = keyRepeat.apply(event(0xE1, true, [.shift]), heldModifiers: [.shift])
        #expect(!started)
        #expect(keyRepeat.key == nil)
    }

    /// ⇧ を離したら、そのあとの繰り返しは ⇧ なしになる。
    @Test func modifierChangeUpdatesRepeatedFlags() {
        var keyRepeat = KeyRepeat()
        _ = keyRepeat.apply(event(0x50, true, [.shift]), heldModifiers: [.shift])
        _ = keyRepeat.apply(event(0xE1, false), heldModifiers: [])
        #expect(keyRepeat.key?.flags == KeyboardMapping.eventFlags(modifiers: [], macVirtualKeyCode: 0x7B))
    }
}
