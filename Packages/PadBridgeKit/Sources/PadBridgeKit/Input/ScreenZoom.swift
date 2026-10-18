import CoreGraphics
import Foundation

/// iPad で Mac のディスプレイを拡大して見るときの、拡大率と表示位置。Mac の文字は iPad では小さいので、ピンチで拡大できるようにする。
public struct ScreenZoom: Sendable, Equatable {
    public static let maximumScale: CGFloat = 5
    // ここまで縮小したら、ちょうど等倍に戻す
    static let snapScale: CGFloat = 1.05

    public private(set) var scale: CGFloat = 1
    /// 表示範囲の中央に来る、映像上の位置 (左上が 0、右下が 1)。
    public private(set) var focus = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public var isZoomed: Bool {
        scale > 1
    }

    /// 等倍のときの映像の位置 `fitted` と表示範囲 `area` から、拡大した映像の配置位置を求める。
    /// 映像が範囲より大きい方向では、端に余白が出ないよう制限する。
    public func rect(fitted: CGRect, in area: CGRect) -> CGRect {
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        guard isZoomed else { return fitted }
        let origin = CGPoint(
            x: Self.clamp(area.midX - focus.x * size.width, length: size.width, area: area.minX ... area.maxX),
            y: Self.clamp(area.midY - focus.y * size.height, length: size.height, area: area.minY ... area.maxY)
        )
        return CGRect(origin: origin, size: size)
    }

    /// ピンチ 1 回分を反映する。`center` の下にある映像の位置が動かないよう拡大し、指が動いた分だけずらす。
    public mutating func apply(scale factor: CGFloat, center: CGPoint, translation: CGVector, fitted: CGRect, area: CGRect) {
        guard fitted.width > 0, fitted.height > 0 else { return }
        let current = rect(fitted: fitted, in: area)
        let newScale = min(max(scale * factor, 1), Self.maximumScale)
        let applied = newScale / scale
        let moved = CGRect(
            x: center.x + (current.minX - center.x) * applied + translation.dx,
            y: center.y + (current.minY - center.y) * applied + translation.dy,
            width: current.width * applied,
            height: current.height * applied
        )
        // 等倍に戻すのは縮小しているときだけにする。拡大しているときにも戻すと、指を大きく開いた位置から始めたピンチ (1 回ごとの倍率が小さい) が毎回戻され、拡大が始まらない
        guard newScale > 1, newScale >= Self.snapScale || factor >= 1 else {
            self = ScreenZoom()
            return
        }
        scale = newScale
        focus = CGPoint(x: (area.midX - moved.minX) / moved.width, y: (area.midY - moved.minY) / moved.height)
        // 制限した位置から表示位置を取り直し、次の拡大が制限前の位置から始まらないようにする
        let clamped = rect(fitted: fitted, in: area)
        focus = CGPoint(x: (area.midX - clamped.minX) / clamped.width, y: (area.midY - clamped.minY) / clamped.height)
    }

    private static func clamp(_ origin: CGFloat, length: CGFloat, area: ClosedRange<CGFloat>) -> CGFloat {
        let areaLength = area.upperBound - area.lowerBound
        guard length > areaLength else {
            // 範囲より小さい方向は、等倍のときと同じく中央に配置する
            return area.lowerBound + (areaLength - length) / 2
        }
        return min(max(origin, area.upperBound - length), area.lowerBound)
    }
}
