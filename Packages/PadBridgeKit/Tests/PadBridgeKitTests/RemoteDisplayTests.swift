import CoreGraphics
@testable import PadBridgeKit
import Testing

struct RemoteDisplayTests {
    private let main = RemoteDisplay.Source(id: 16, name: "VG258", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true, isMirror: false)

    /// この Mac と同じく、名前のない 2 台目がメインディスプレイの左にある。
    @Test func listsDisplaysLeftToRightAndNamesUnnamedOnes() {
        let left = RemoteDisplay.Source(id: 15, name: "", bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isMain: false, isMirror: false)
        let displays = RemoteDisplay.list([main, left])
        #expect(displays == [
            RemoteDisplay(id: 15, name: RemoteDisplay.unnamed, placement: .left),
            RemoteDisplay(id: 16, name: "VG258", placement: .main),
        ])
        #expect(displays.map(\.label) == ["名称不明のディスプレイ (メインディスプレイの左)", "VG258 (メインディスプレイ)"])
    }

    /// 同じ機種を 2 台ともメインディスプレイの右に並べても、左から番号を付けて区別できる。
    @Test func numbersDisplaysWithSameNameAndPlacement() {
        let near = RemoteDisplay.Source(id: 2, name: "DELL U2720Q", bounds: CGRect(x: 1920, y: 0, width: 2560, height: 1440), isMain: false, isMirror: false)
        let far = RemoteDisplay.Source(id: 3, name: "DELL U2720Q", bounds: CGRect(x: 4480, y: 0, width: 2560, height: 1440), isMain: false, isMirror: false)
        #expect(RemoteDisplay.list([far, main, near]).map(\.label) == ["VG258 (メインディスプレイ)", "DELL U2720Q 1 (メインディスプレイの右)", "DELL U2720Q 2 (メインディスプレイの右)"])
    }

    @Test func excludesMirroredDisplays() {
        let mirror = RemoteDisplay.Source(id: 3, name: "プロジェクタ", bounds: main.bounds, isMain: false, isMirror: true)
        #expect(RemoteDisplay.list([mirror, main]).map(\.id) == [16])
    }

    /// 縦に積んだディスプレイは上下、ずらして置いたディスプレイはずれの大きい向きで決める。
    @Test(arguments: [
        (CGRect(x: 1920, y: 200, width: 2560, height: 1440), RemoteDisplay.Placement.right),
        (CGRect(x: 0, y: -1440, width: 2560, height: 1440), .above),
        (CGRect(x: 300, y: 1080, width: 1512, height: 982), .below),
        (CGRect(x: -1512, y: 900, width: 1512, height: 982), .left),
    ])
    func placesDisplaysRelativeToMain(bounds: CGRect, placement: RemoteDisplay.Placement) {
        #expect(RemoteDisplay.placement(of: bounds, from: main.bounds) == placement)
    }

    /// 最前面のウィンドウのディスプレイを表示する。複数にまたがっていれば重なりの大きい方、どこにも重ならなければ追従しない。
    @Test func findsDisplayShowingWindow() {
        let displays: [UInt32: CGRect] = [15: CGRect(x: -1920, y: 0, width: 1920, height: 1080), 16: main.bounds]
        #expect(RemoteDisplay.showing(window: CGRect(x: -1500, y: 100, width: 800, height: 600), displays: displays) == 15)
        #expect(RemoteDisplay.showing(window: CGRect(x: -300, y: 100, width: 1200, height: 600), displays: displays) == 16)
        #expect(RemoteDisplay.showing(window: CGRect(x: -700, y: 0, width: 1200, height: 600), displays: displays) == 15)
        #expect(RemoteDisplay.showing(window: CGRect(x: 2000, y: 0, width: 100, height: 100), displays: displays) == nil)
        #expect(RemoteDisplay.showing(window: CGRect(x: -100, y: 0, width: 200, height: 100), displays: displays) == 15)
    }

    /// 移動先でも、元のディスプレイでの寄せ方 (左上・中央・右下) を維持する。
    @Test func movedWindowKeepsItsPlaceOnTheOtherDisplay() {
        let main = CGRect(x: 0, y: 33, width: 1920, height: 1047)
        let left = CGRect(x: -1920, y: 33, width: 1920, height: 1047)
        #expect(RemoteDisplay.moved(window: CGRect(x: 0, y: 33, width: 800, height: 600), from: main, to: left) == CGRect(x: -1920, y: 33, width: 800, height: 600))
        #expect(RemoteDisplay.moved(window: CGRect(x: 560, y: 256.5, width: 800, height: 600), from: main, to: left) == CGRect(x: -1360, y: 256.5, width: 800, height: 600))
        #expect(RemoteDisplay.moved(window: CGRect(x: 1120, y: 480, width: 800, height: 600), from: main, to: left) == CGRect(x: -800, y: 480, width: 800, height: 600))
    }

    /// 大きなディスプレイいっぱいのウィンドウは、移動先の小さなディスプレイに収まるよう縮小する。
    @Test func movedWindowShrinksToFitSmallerDisplay() {
        let large = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let small = CGRect(x: 2560, y: 33, width: 1512, height: 949)
        #expect(RemoteDisplay.moved(window: large, from: large, to: small) == small)
        #expect(RemoteDisplay.moved(window: CGRect(x: 100, y: 25, width: 2000, height: 700), from: large, to: small) == CGRect(x: 2560, y: 33, width: 1512, height: 700))
    }

    /// 取り外したディスプレイに残ってどのディスプレイにも重ならないウィンドウは、移動先を元の範囲として計算すると、移動先のディスプレイ内に収まる (Host が回収するときの計算)。
    @Test func offscreenWindowIsPulledIntoDestination() {
        let left = CGRect(x: -1920, y: 33, width: 1920, height: 1047)
        let usable: [UInt32: CGRect] = [16: main.bounds, 15: left]
        let offscreen = CGRect(x: -4000, y: 200, width: 800, height: 600)
        #expect(RemoteDisplay.showing(window: offscreen, displays: usable) == nil)
        let moved = RemoteDisplay.moved(window: offscreen, from: left, to: left)
        #expect(left.contains(moved))
        #expect(moved.size == offscreen.size)
    }

    /// 選択したディスプレイが外れたらメインディスプレイを表示し、再接続されたらまた選択したディスプレイを表示する。
    @Test func showsPreferredDisplayWhileConnectedElseMain() {
        let both = [RemoteDisplay(id: 15, name: "A", placement: .left), RemoteDisplay(id: 16, name: "B", placement: .main)]
        #expect(RemoteDisplay.shown(preferred: 15, in: both) == 15)
        #expect(RemoteDisplay.shown(preferred: 15, in: [both[1]]) == 16)
        #expect(RemoteDisplay.shown(preferred: nil, in: both) == 16)
        #expect(RemoteDisplay.shown(preferred: nil, in: []) == nil)
    }
}
