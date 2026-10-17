@testable import PadBridgeKit
import Testing

struct PairingCodeTests {
    @Test func generatedCodeIsValid() {
        for _ in 0 ..< 100 {
            let code = PairingCode.generate()
            #expect(PairingCode(code.value) == code)
            #expect(code.formatted.count == 11)
        }
    }

    @Test func inputIsNormalized() {
        #expect(PairingCode("abcde-fghjk")?.value == "ABCDEFGHJK")
        #expect(PairingCode(" ABCDE FGHJK ")?.value == "ABCDEFGHJK")
    }

    @Test(arguments: ["ABCDEFGHJ", "ABCDEFGHJKM", "ABCDEFGHJ0", "ABCDEFGHJI"])
    func invalidInputIsRejected(input: String) {
        #expect(PairingCode(input) == nil)
    }

    @Test func differentCodesDeriveDifferentKeys() {
        #expect(PairingCode("ABCDEFGHJK")!.preSharedKey != PairingCode("ABCDEFGHJM")!.preSharedKey)
        #expect(PairingCode("ABCDEFGHJK")!.preSharedKey.count == 32)
    }
}

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
