import Foundation

/// iPad から届いたスクロールの量 (画面の幅・高さに対する割合) を、Mac のホイールのピクセルにする。
public struct ScrollWheel: Sendable {
    /// 1 回に送る量の上限。極端な値が届いても、Int32 に収まらずに Host が止まらないように (ペアリングなしで、同じ LAN の誰でも送れる)
    public static let maxPixels: Double = 10_000

    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    /// ホイールの量 (ピクセル)。1 ピクセル未満の端数は持ち越し、ゆっくり動かしたときの移動を消さない。動かす量がなければ nil。
    public mutating func pixels(dx: Double, dy: Double, width: Double, height: Double) -> (x: Int32, y: Int32)? {
        guard dx.isFinite, dy.isFinite, width.isFinite, height.isFinite else { return nil }
        remainderX = Self.clamp(remainderX + dx * width)
        remainderY = Self.clamp(remainderY + dy * height)
        let x = Int32(remainderX.rounded(.towardZero))
        let y = Int32(remainderY.rounded(.towardZero))
        guard x != 0 || y != 0 else { return nil }
        remainderX -= Double(x)
        remainderY -= Double(y)
        return (x, y)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -maxPixels), maxPixels)
    }
}
