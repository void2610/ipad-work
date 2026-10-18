import CoreGraphics
@testable import PadBridgeKit
import Testing

struct RemoteDisplayTests {
    private let main = RemoteDisplay.Source(id: 16, name: "VG258", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true, isMirror: false)

    /// この Mac と同じく、名前を持たない 2 台目がメインの左にある。
    @Test func listsDisplaysLeftToRightAndNamesUnnamedOnes() {
        let left = RemoteDisplay.Source(id: 15, name: "", bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isMain: false, isMirror: false)
        let displays = RemoteDisplay.list([main, left])
        #expect(displays == [
            RemoteDisplay(id: 15, name: RemoteDisplay.unnamed, placement: .left),
            RemoteDisplay(id: 16, name: "VG258", placement: .main),
        ])
        #expect(displays.map(\.label) == ["名前のない画面 (メインの左)", "VG258 (メイン)"])
    }

    @Test func excludesMirroredDisplays() {
        let mirror = RemoteDisplay.Source(id: 3, name: "プロジェクタ", bounds: main.bounds, isMain: false, isMirror: true)
        #expect(RemoteDisplay.list([mirror, main]).map(\.id) == [16])
    }

    /// 縦に積んだ画面は上下、ずらして置いた画面はずれの大きい向きで決める。
    @Test(arguments: [
        (CGRect(x: 1920, y: 200, width: 2560, height: 1440), RemoteDisplay.Placement.right),
        (CGRect(x: 0, y: -1440, width: 2560, height: 1440), .above),
        (CGRect(x: 300, y: 1080, width: 1512, height: 982), .below),
        (CGRect(x: -1512, y: 900, width: 1512, height: 982), .left),
    ])
    func placesDisplaysRelativeToMain(bounds: CGRect, placement: RemoteDisplay.Placement) {
        #expect(RemoteDisplay.placement(of: bounds, from: main.bounds) == placement)
    }

    /// 前に出たウィンドウの画面を映す。またいでいれば重なりの大きい方、どこにも重ならなければ追わない。
    @Test func findsDisplayShowingWindow() {
        let displays: [UInt32: CGRect] = [15: CGRect(x: -1920, y: 0, width: 1920, height: 1080), 16: main.bounds]
        #expect(RemoteDisplay.showing(window: CGRect(x: -1500, y: 100, width: 800, height: 600), displays: displays) == 15)
        #expect(RemoteDisplay.showing(window: CGRect(x: -300, y: 100, width: 1200, height: 600), displays: displays) == 16)
        #expect(RemoteDisplay.showing(window: CGRect(x: -700, y: 0, width: 1200, height: 600), displays: displays) == 15)
        #expect(RemoteDisplay.showing(window: CGRect(x: 2000, y: 0, width: 100, height: 100), displays: displays) == nil)
        #expect(RemoteDisplay.showing(window: CGRect(x: -100, y: 0, width: 200, height: 100), displays: displays) == 15)
    }

    /// 選んだ画面が外れたらメインを映し、つなぎ直されたらまた選んだ画面を映す。
    @Test func showsPreferredDisplayWhileConnectedElseMain() {
        let both = [RemoteDisplay(id: 15, name: "A", placement: .left), RemoteDisplay(id: 16, name: "B", placement: .main)]
        #expect(RemoteDisplay.shown(preferred: 15, in: both) == 15)
        #expect(RemoteDisplay.shown(preferred: 15, in: [both[1]]) == 16)
        #expect(RemoteDisplay.shown(preferred: nil, in: both) == 16)
        #expect(RemoteDisplay.shown(preferred: nil, in: []) == nil)
    }
}
