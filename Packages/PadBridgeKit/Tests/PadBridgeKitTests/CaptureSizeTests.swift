import CoreGraphics
@testable import PadBridgeKit
import Testing

struct CaptureSizeTests {
    private func fit(_ width: CGFloat, _ height: CGFloat) -> [Int] {
        let size = CaptureSize.fitting(pixelWidth: width, pixelHeight: height, limitWidth: 2360, limitHeight: 1640)
        return [size.width, size.height]
    }

    /// MacBook の内蔵の画面は iPad より細かいので縮める (実機で配信している 2360x1532)。
    @Test func shrinksRetinaDisplayToPad() {
        #expect(fit(3600, 2338) == [2360, 1532])
    }

    @Test func keepsDisplaySmallerThanPad() {
        #expect(fit(1920, 1080) == [1920, 1080])
    }

    /// 縦に置いたディスプレイは、iPad を縦にしたときの画素数に収まればそのまま送る。
    @Test func keepsPortraitDisplayThatFitsPortraitPad() {
        #expect(fit(1080, 1920) == [1080, 1920])
        #expect(fit(1440, 2560) == [1326, 2360])
    }

    @Test func shrinksLargeDisplayToEvenSize() {
        #expect(fit(5120, 2880) == [2360, 1326])
    }
}
