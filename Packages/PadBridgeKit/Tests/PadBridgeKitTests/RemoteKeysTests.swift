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
}
