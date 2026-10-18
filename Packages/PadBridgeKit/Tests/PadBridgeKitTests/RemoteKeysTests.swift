import Foundation
@testable import PadBridgeKit
import Testing

struct RemoteKeysTests {
    /// 3 本指で払ったときに送る並びが、Mac で Mission Control などを起こすのと同じ「Control 押下 → 矢印 → Control 解放」になること。
    @Test func controlArrowWrapsArrowInControl() {
        #expect(RemoteKeys.controlArrow(usage: KeyboardMapping.ArrowUsage.up) == [
            .key(usage: 0xE0, isDown: true, modifiers: [.control]),
            .key(usage: 0x52, isDown: true, modifiers: [.control]),
            .key(usage: 0x52, isDown: false, modifiers: [.control]),
            .key(usage: 0xE0, isDown: false, modifiers: []),
        ])
    }

    /// Mac 側で合成すると、Control は修飾状態の変化、矢印は Fn・テンキー付きのキー押下になること。
    @Test func controlArrowBecomesKeyboardAccurateMacEvents() {
        let events = RemoteKeys.controlArrow(usage: KeyboardMapping.ArrowUsage.right).compactMap { message -> MacKeyEvent? in
            guard case let .key(usage, isDown, modifiers) = message else { return nil }
            return MacKeyEvent(usage: usage, isDown: isDown, modifiers: modifiers)
        }
        #expect(events.map(\.keyCode) == [0x3B, 0x7C, 0x7C, 0x3B])
        #expect(events.map(\.isFlagsChanged) == [true, false, false, true])
        #expect(events[1].flags == 0x40101 | 0x200000 | 0x800000)
        #expect(events[3].flags == 0x100)
    }

    /// キーボード上の列の英数・かなが、Mac の JIS キーボードの英数キー・かなキーになること。
    @Test func eisuAndKanaBecomeJISKeys() {
        let eisu = MacKeyEvent(usage: 0x91, isDown: true, modifiers: [])
        let kana = MacKeyEvent(usage: 0x90, isDown: true, modifiers: [])
        #expect(eisu?.keyCode == 0x66)
        #expect(kana?.keyCode == 0x68)
        #expect(eisu?.isFlagsChanged == false)
        #expect(kana?.flags == 0x100)
    }

    /// キーボード上の列の esc・Tab が、修飾キーなしでそのまま届くこと。
    @Test func escapeAndTabAreSentAsPlainKeys() {
        #expect(MacKeyEvent(usage: 0x29, isDown: true, modifiers: [])?.keyCode == 0x35)
        #expect(MacKeyEvent(usage: 0x2B, isDown: true, modifiers: [])?.keyCode == 0x30)
        #expect(RemoteKeys.withModifiers([], RemoteKeys.tap(usage: 0x29)) == RemoteKeys.tap(usage: 0x29))
    }

    /// Dock を出すのは Control を押したままの F3。F3 には実際のキーボードと同じく Fn のビットが付く。
    @Test func focusDockIsControlF3() {
        #expect(RemoteKeys.focusDock() == [
            .key(usage: 0xE0, isDown: true, modifiers: [.control]),
            .key(usage: 0x3C, isDown: true, modifiers: [.control]),
            .key(usage: 0x3C, isDown: false, modifiers: [.control]),
            .key(usage: 0xE0, isDown: false, modifiers: []),
        ])
        let f3 = MacKeyEvent(usage: 0x3C, isDown: true, modifiers: [.control])
        #expect(f3?.keyCode == 0x63)
        #expect(f3?.flags == 0x40101 | 0x800000)
    }

    @Test func plainArrowCarriesFunctionAndKeypadFlags() {
        let event = MacKeyEvent(usage: KeyboardMapping.ArrowUsage.left, isDown: true, modifiers: [])
        #expect(event?.keyCode == 0x7B)
        #expect(event?.flags == 0x100 | 0x200000 | 0x800000)
    }
}

struct AppSwitcherTests {
    private let commandDown = ControlMessage.key(usage: 0xE3, isDown: true, modifiers: [.command])
    private let commandUp = ControlMessage.key(usage: 0xE3, isDown: false, modifiers: [])
    private let tab = RemoteKeys.tap(usage: 0x2B, modifiers: [.command])

    @Test func firstTapHoldsCommandAndSendsTab() {
        var switcher = AppSwitcher()
        #expect(switcher.tap(at: 0) == [commandDown] + tab)
        #expect(switcher.isSwitching)
    }

    /// 続けてタップすると Command を押したまま Tab だけを足し、最後のタップから 1 秒で確定すること。
    @Test func repeatedTapsAdvanceAndCommitAfterIdle() {
        var switcher = AppSwitcher()
        _ = switcher.tap(at: 0)
        #expect(switcher.commitIfDue(at: 0.6).isEmpty)
        #expect(switcher.tap(at: 0.6) == tab)
        #expect(switcher.commitIfDue(at: 1.5).isEmpty)
        #expect(switcher.commitIfDue(at: 1.6) == [commandUp])
        #expect(!switcher.isSwitching)
        #expect(switcher.commitIfDue(at: 3).isEmpty)
    }

    @Test func immediateCommitReleasesCommandOnce() {
        var switcher = AppSwitcher()
        _ = switcher.tap(at: 0)
        #expect(switcher.commit() == [commandUp])
        #expect(switcher.commit().isEmpty)
    }

    /// ⌘F のようなショートカットは、修飾キーを付けた F の押し離しだけにする (⌘ そのものは押したときに送っている)。
    @Test func shortcutTapsKeyWithModifiers() {
        #expect(RemoteKeys.shortcut("f", modifiers: .command) == [
            .key(usage: 0x09, isDown: true, modifiers: .command),
            .key(usage: 0x09, isDown: false, modifiers: .command),
        ])
        #expect(RemoteKeys.shortcut("N", modifiers: .command) == RemoteKeys.tap(usage: 0x11, modifiers: [.command, .shift]))
        #expect(RemoteKeys.shortcut("ab", modifiers: .command).isEmpty)
    }
}
