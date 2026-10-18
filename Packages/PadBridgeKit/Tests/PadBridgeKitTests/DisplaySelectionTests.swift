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

    /// 選んだ画面を外すとメインを映し、つなぎ直すとまた選んだ画面を映す。
    @Test func fallsBackWhilePreferredIsUnpluggedAndReturns() {
        var selection = selection([left, main], preferred: 15)
        var result = selection.update([main], preferred: 15)
        #expect(result == .init(isShownChanged: true, needsAnnouncement: true))
        #expect(selection.shownID == 16)
        result = selection.update([left, main], preferred: 15)
        #expect(result == .init(isShownChanged: true, needsAnnouncement: true))
        #expect(selection.shownID == 15)
    }

    /// 解像度だけが変わったときなど、一覧も映す画面も同じなら iPad に知らせ直さない。
    @Test func sameListNeedsNoAnnouncement() {
        var selection = selection([left, main], preferred: nil)
        let result = selection.update([left, main], preferred: nil)
        #expect(result == .init(isShownChanged: false, needsAnnouncement: false))
    }

    /// 映す画面はそのままで、ほかの画面がつながったときは一覧だけ知らせ直す。
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

    /// 取り込めない画面からはメインへ落とす。メインを映していれば落とす先はない。
    @Test func fallsBackToMainOnlyFromOtherDisplay() {
        var selection = selection([left, main], preferred: 15)
        let first = selection.fallBackToMain()
        #expect(first)
        #expect(selection.shownID == 16)
        let second = selection.fallBackToMain()
        #expect(!second)
    }
}
