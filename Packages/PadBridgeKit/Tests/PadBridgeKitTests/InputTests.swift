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
