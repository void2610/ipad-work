import CoreGraphics
import Foundation

/// Mac のディスプレイのうち、映像として送る範囲。ディスプレイ全体を 0...1 とした割合で表す。
/// iPad で拡大している間は見えている範囲だけを Mac の解像度で切り出して送り、拡大しても文字がぼやけないようにする。
public struct VideoRegion: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = VideoRegion(x: 0, y: 0, width: 1, height: 1)
    // 少しずらしただけで再要求しないよう、この刻みに丸める
    static let step = 1.0 / 128

    /// ディスプレイの外や大きさのない範囲は、ディスプレイの内側に収める。NaN などが届いて、iPad の表示位置や Mac の切り出しが壊れないようにする
    public init(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            (self.x, self.y, self.width, self.height) = (0, 0, 1, 1)
            return
        }
        self.width = min(max(width, Self.step), 1)
        self.height = min(max(height, Self.step), 1)
        self.x = min(max(x, 0), 1 - self.width)
        self.y = min(max(y, 0), 1 - self.height)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x), y: container.decode(Double.self, forKey: .y),
            width: container.decode(Double.self, forKey: .width), height: container.decode(Double.self, forKey: .height)
        )
    }

    public var isFull: Bool {
        self == .full
    }

    /// 拡大した映像の位置 `zoomed` と表示範囲 `area` から、送ってほしい範囲を求める。
    /// 見えている範囲に `margin` の割合の余白を足し、アスペクト比をディスプレイ全体と同じにする (切り出しても映像のサイズを変えずに送れるように)。
    public static func visible(zoomed: CGRect, area: CGRect, margin: Double = 0.15) -> VideoRegion {
        guard zoomed.width > 0, zoomed.height > 0 else { return .full }
        let shown = zoomed.intersection(area)
        guard !shown.isNull else { return .full }
        let width = Double(shown.width / zoomed.width)
        let height = Double(shown.height / zoomed.height)
        // ディスプレイ全体に対する割合でアスペクト比をそろえるには、幅と高さの割合を同じにすればよい
        let side = min(max(width, height) * (1 + 2 * margin), 1)
        guard side < 1 - step else { return .full }
        let centerX = Double((shown.midX - zoomed.minX) / zoomed.width)
        let centerY = Double((shown.midY - zoomed.minY) / zoomed.height)
        let rounded = (side / step).rounded(.up) * step
        func origin(_ center: Double) -> Double {
            let value = ((center - rounded / 2) / step).rounded() * step
            return min(max(value, 0), 1 - rounded)
        }
        return VideoRegion(x: origin(centerX), y: origin(centerY), width: rounded, height: rounded)
    }

    /// ディスプレイ全体を `full` に置いたときに、この範囲が占める位置。
    public func rect(in full: CGRect) -> CGRect {
        CGRect(
            x: full.minX + CGFloat(x) * full.width,
            y: full.minY + CGFloat(y) * full.height,
            width: CGFloat(width) * full.width,
            height: CGFloat(height) * full.height
        )
    }
}
