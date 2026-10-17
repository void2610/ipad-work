import CoreGraphics
import Foundation

/// iPad で Mac の画面を拡大して見るときの、拡大率と見ている位置。Mac の文字は iPad では小さいので、ピンチで拡大できるようにする。
public struct ScreenZoom: Sendable, Equatable {
    public static let maximumScale: CGFloat = 5
    // ここまで縮めたら、ぴったり等倍に戻す
    static let snapScale: CGFloat = 1.05

    public private(set) var scale: CGFloat = 1
    /// 映す範囲の中央に来る、映像の上の位置 (左上が 0、右下が 1)。
    public private(set) var focus = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public var isZoomed: Bool {
        scale > 1
    }

    /// 等倍のときの映像の位置 `fitted` と映す範囲 `area` から、拡大した映像を置く位置を出す。
    /// 映像が範囲より大きい向きでは、端に余白が出ないよう押さえる。
    public func rect(fitted: CGRect, in area: CGRect) -> CGRect {
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        guard isZoomed else { return fitted }
        let origin = CGPoint(
            x: Self.clamp(area.midX - focus.x * size.width, length: size.width, area: area.minX ... area.maxX),
            y: Self.clamp(area.midY - focus.y * size.height, length: size.height, area: area.minY ... area.maxY)
        )
        return CGRect(origin: origin, size: size)
    }

    /// ピンチの 1 回分を反映する。`center` の下にある映像の位置が動かないよう拡大し、指が動いた分だけずらす。
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
        guard newScale >= Self.snapScale else {
            self = ScreenZoom()
            return
        }
        scale = newScale
        focus = CGPoint(x: (area.midX - moved.minX) / moved.width, y: (area.midY - moved.minY) / moved.height)
        // 押さえた位置から見ている位置を取り直し、次の拡大が押さえる前の位置から始まらないようにする
        let clamped = rect(fitted: fitted, in: area)
        focus = CGPoint(x: (area.midX - clamped.minX) / clamped.width, y: (area.midY - clamped.minY) / clamped.height)
    }

    private static func clamp(_ origin: CGFloat, length: CGFloat, area: ClosedRange<CGFloat>) -> CGFloat {
        let areaLength = area.upperBound - area.lowerBound
        guard length > areaLength else {
            // 範囲より小さい向きは、等倍のときと同じく中央に置く
            return area.lowerBound + (areaLength - length) / 2
        }
        return min(max(origin, area.upperBound - length), area.lowerBound)
    }
}
