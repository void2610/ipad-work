import Foundation
@testable import PadBridgeKit
import Testing

struct ModifierLatchTests {
    @Test func singleTapAppliesToNextActionOnly() {
        var latch = ModifierLatch()
        latch.tap(.command, at: 0)
        #expect(latch.state(of: .command) == .once)
        #expect(latch.active == [.command])
        latch.consume()
        #expect(latch.active.isEmpty)
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var latch = ModifierLatch()
        latch.tap(.shift, at: 0)
        latch.tap(.shift, at: 0.2)
        #expect(latch.state(of: .shift) == .locked)
        latch.consume()
        #expect(latch.active == [.shift])
        latch.tap(.shift, at: 2)
        #expect(latch.active.isEmpty)
    }

    @Test func slowSecondTapTurnsOff() {
        var latch = ModifierLatch()
        latch.tap(.option, at: 0)
        latch.tap(.option, at: 1)
        #expect(latch.state(of: .option) == .off)
    }

    @Test func modifiersCombine() {
        var latch = ModifierLatch()
        latch.tap(.command, at: 0)
        latch.tap(.shift, at: 0.1)
        #expect(latch.active == [.command, .shift])
    }
}

struct HeldModifiersTests {
    /// ハードウェアキーボードで ⌘ を押したままタップすると、クリックに ⌘ が載ること。
    @Test func heldCommandIsAppliedToMouseEvents() {
        var held = HeldModifiers()
        held.apply(MacKeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])!)
        #expect(held.modifiers == [.command])
        #expect(held.mouseEventFlags == 0x100108)
        held.apply(MacKeyEvent(usage: 0xE3, isDown: false, modifiers: [])!)
        #expect(held.mouseEventFlags == 0x100)
    }

    /// iPadOS が ⌘ を外して渡した ⌘. も、押している ⌘ を載せて送る。修飾キーそのもののイベントは変えない。
    @Test func heldModifiersAreAddedToOrdinaryKeys() {
        var held = HeldModifiers()
        held.apply(MacKeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])!)
        #expect(held.keyEvent(usage: 0x37, isDown: true, modifiers: []) == MacKeyEvent(usage: 0x37, isDown: true, modifiers: [.command]))
        #expect(held.keyEvent(usage: 0x37, isDown: true, modifiers: [.shift]) == MacKeyEvent(usage: 0x37, isDown: true, modifiers: [.command, .shift]))
        #expect(held.keyEvent(usage: 0xE3, isDown: false, modifiers: []) == MacKeyEvent(usage: 0xE3, isDown: false, modifiers: []))
        held.apply(MacKeyEvent(usage: 0xE3, isDown: false, modifiers: [])!)
        #expect(held.keyEvent(usage: 0x37, isDown: true, modifiers: []) == MacKeyEvent(usage: 0x37, isDown: true, modifiers: []))
    }

    @Test func ordinaryKeysDoNotCount() {
        var held = HeldModifiers()
        held.apply(MacKeyEvent(usage: 0x04, isDown: true, modifiers: [])!)
        #expect(held.modifiers.isEmpty)
    }
}

struct TypedTextTests {
    private func tap(_ usage: Int, _ modifiers: KeyModifiers = []) -> [ControlMessage] {
        RemoteKeys.tap(usage: usage, modifiers: modifiers)
    }

    @Test func lettersAndDigitsAreSentAsKeys() {
        #expect(RemoteKeys.typed("a1 ") == tap(0x04) + tap(0x1E) + tap(0x2C))
    }

    @Test func uppercaseHoldsShift() {
        #expect(RemoteKeys.typed("A") == [
            .key(usage: 0xE1, isDown: true, modifiers: [.shift]),
            .key(usage: 0x04, isDown: true, modifiers: [.shift]),
            .key(usage: 0x04, isDown: false, modifiers: [.shift]),
            .key(usage: 0xE1, isDown: false, modifiers: []),
        ])
    }

    /// 配列で記号の位置が変わるので、記号や日本語はまとめて文字として挿入すること。
    @Test func otherCharactersAreInsertedAsText() {
        #expect(RemoteKeys.typed("@あ#x") == [.insertText("@あ#")] + tap(0x1B))
    }

    /// US と JIS で位置が同じ記号は、Mac の日本語入力が「ー」「、」「。」に変えられるようキーとして送ること。
    @Test func layoutIndependentSymbolsAreSentAsKeys() {
        #expect(RemoteKeys.typed("-,./") == tap(0x2D) + tap(0x36) + tap(0x37) + tap(0x38))
        #expect(RemoteKeys.typed("?") == RemoteKeys.withModifiers([.shift], tap(0x38)))
        #expect(RemoteKeys.typed("!") == RemoteKeys.withModifiers([.shift], tap(0x1E)))
    }

    @Test func newlineIsReturnKey() {
        #expect(RemoteKeys.typed("\n") == tap(0x28))
    }

    /// ⌘ が有効なときに c を打つと ⌘C になること。
    @Test func commandWithLetterBecomesShortcut() {
        #expect(RemoteKeys.typed("c", modifiers: [.command]) == [
            .key(usage: 0xE3, isDown: true, modifiers: [.command]),
            .key(usage: 0x06, isDown: true, modifiers: [.command]),
            .key(usage: 0x06, isDown: false, modifiers: [.command]),
            .key(usage: 0xE3, isDown: false, modifiers: []),
        ])
    }

    @Test func modifiersWrapClicksInOrder() {
        let click: [ControlMessage] = [.mouseButton(.left, isDown: true, at: NormalizedPoint(x: 0.5, y: 0.5))]
        #expect(RemoteKeys.withModifiers([.command, .shift], click) == [
            .key(usage: 0xE3, isDown: true, modifiers: [.command]),
            .key(usage: 0xE1, isDown: true, modifiers: [.command, .shift]),
        ] + click + [
            .key(usage: 0xE1, isDown: false, modifiers: [.command]),
            .key(usage: 0xE3, isDown: false, modifiers: []),
        ])
    }
}

struct PointerModifierHoldTests {
    private let point = NormalizedPoint(x: 0.5, y: 0.5)
    private let commandDown = ControlMessage.key(usage: 0xE3, isDown: true, modifiers: [.command])
    private let commandUp = ControlMessage.key(usage: 0xE3, isDown: false, modifiers: [])

    @Test func clickIsWrappedInModifiers() {
        var hold = PointerModifierHold()
        let click: [ControlMessage] = [.mouseMove(point), .mouseButton(.left, isDown: true, at: point), .mouseButton(.left, isDown: false, at: point)]
        let result = hold.wrap(click, modifiers: [.command])
        #expect(result.didUseModifiers)
        #expect(result.messages == [.mouseMove(point), commandDown, click[1], click[2], commandUp])
    }

    /// ドラッグは押すときと離すときが別の送信になるので、離すまで修飾キーを押したままにすること。
    @Test func dragKeepsModifiersUntilRelease() {
        var hold = PointerModifierHold()
        let down = hold.wrap([.mouseButton(.left, isDown: true, at: point), .mouseMove(point)], modifiers: [.command])
        #expect(down.messages == [commandDown, .mouseButton(.left, isDown: true, at: point), .mouseMove(point)])
        let moves = hold.wrap([.mouseMove(point)], modifiers: [])
        #expect(moves.messages == [.mouseMove(point)])
        let up = hold.wrap([.mouseButton(.left, isDown: false, at: point)], modifiers: [])
        #expect(up.messages == [.mouseButton(.left, isDown: false, at: point), commandUp])
    }

    @Test func noModifiersPassesThrough() {
        var hold = PointerModifierHold()
        let click: [ControlMessage] = [.mouseButton(.left, isDown: true, at: point), .mouseButton(.left, isDown: false, at: point)]
        let result = hold.wrap(click, modifiers: [])
        #expect(!result.didUseModifiers)
        #expect(result.messages == click)
    }
}
