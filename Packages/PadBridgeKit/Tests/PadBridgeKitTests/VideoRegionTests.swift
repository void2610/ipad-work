import CoreGraphics
@testable import PadBridgeKit
import Testing

struct VideoRegionTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 700)

    @Test func unzoomedIsFull() {
        #expect(VideoRegion.visible(zoomed: CGRect(x: 0, y: 25, width: 1000, height: 650), area: area) == .full)
    }

    /// 2 倍に拡大して中央を見ているときは、中央の半分ほど (余白込み) を頼むこと。
    @Test func zoomedCenterAsksForCenterWithMargin() {
        let zoomed = CGRect(x: -500, y: -300, width: 2000, height: 1300)
        let region = VideoRegion.visible(zoomed: zoomed, area: area, margin: 0)
        #expect(region.width == region.height)
        #expect(abs(region.width - 0.5390625) < 0.0001)
        #expect(abs(region.x + region.width / 2 - 0.5) < VideoRegion.step)
    }

    /// 端を見ているときも、範囲が画面の外にはみ出さないこと。
    @Test func regionStaysInsideScreen() {
        let zoomed = CGRect(x: 0, y: 0, width: 3000, height: 1950)
        let region = VideoRegion.visible(zoomed: zoomed, area: area)
        #expect(region.x == 0)
        #expect(region.y == 0)
        #expect(region.x + region.width <= 1)
    }

    @Test func regionMapsIntoFullRect() {
        let region = VideoRegion(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        #expect(region.rect(in: CGRect(x: 10, y: 20, width: 400, height: 200)) == CGRect(x: 110, y: 120, width: 200, height: 50))
    }
}
