@testable import PadBridgeKit
import Testing

struct DisplaySelectionTests {
    private let left = RemoteDisplay(id: 15, name: RemoteDisplay.unnamed, placement: .left)
    private let main = RemoteDisplay(id: 16, name: "VG258", placement: .main)

    private func selection(_ displays: [RemoteDisplay], preferred: UInt32?) -> DisplaySelection {
        var selection = DisplaySelection()
        _ = selection.update(displays, preferred: preferred)
        return selection
    }

    @Test func startsOnMainUnlessPreferredIsConnected() {
        var selection = DisplaySelection()
        let result = selection.update([left, main], preferred: nil)
        #expect(result == .init(isShownChanged: true, needsAnnouncement: true))
        #expect(selection.shownID == 16)
        #expect(selection.announcement == .displays([left, main], shownID: 16))
        #expect(self.selection([left, main], preferred: 15).shownID == 15)
    }

    /// 選択したディスプレイを外すとメインディスプレイを表示し、再接続するとまた選択したディスプレイを表示する。
    @Test func fallsBackWhilePreferredIsUnpluggedAndReturns() {
        var selection = selection([left, main], preferred: 15)
        var result = selection.update([main], preferred: 15)
        #expect(result == .init(isShownChanged: true, needsAnnouncement: true))
        #expect(selection.shownID == 16)
        result = selection.update([left, main], preferred: 15)
        #expect(result == .init(isShownChanged: true, needsAnnouncement: true))
        #expect(selection.shownID == 15)
    }

    /// 解像度だけが変わったときなど、一覧も表示中のディスプレイも同じなら iPad に再通知しない。
    @Test func sameListNeedsNoAnnouncement() {
        var selection = selection([left, main], preferred: nil)
        let result = selection.update([left, main], preferred: nil)
        #expect(result == .init(isShownChanged: false, needsAnnouncement: false))
    }

    /// 表示中のディスプレイはそのままで、ほかのディスプレイが接続されたときは一覧だけ再通知する。
    @Test func newDisplayIsAnnouncedWithoutSwitching() {
        var selection = selection([main], preferred: nil)
        let result = selection.update([left, main], preferred: nil)
        #expect(result == .init(isShownChanged: false, needsAnnouncement: true))
    }

    @Test func switchesOnlyToConnectedOtherDisplay() {
        var selection = selection([left, main], preferred: nil)
        var result = selection.switchTo(99)
        #expect(result == .missing)
        #expect(selection.shownID == 16)
        result = selection.switchTo(16)
        #expect(result == .alreadyShown)
        #expect(selection.switchTo(15) == .switched)
        #expect(selection.shownID == 15)
    }

    /// キャプチャできないディスプレイからはメインディスプレイへ切り替える。メインディスプレイを表示中なら切り替え先はない。
    @Test func fallsBackToMainOnlyFromOtherDisplay() {
        var selection = selection([left, main], preferred: 15)
        let first = selection.fallBackToMain()
        #expect(first)
        #expect(selection.shownID == 16)
        let second = selection.fallBackToMain()
        #expect(!second)
    }
}
