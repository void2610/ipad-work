import CoreGraphics

/// Mac の画面を取り込む大きさ。iPad の画素数より細かく送っても見えないので、そこまで縮める。
public enum CaptureSize {
    /// `limitWidth`・`limitHeight` は iPad の画素数 (向きは問わない)。
    /// 縦に置いたディスプレイは iPad を縦にして見られるので、長い辺どうし・短い辺どうしで比べる。
    public static func fitting(pixelWidth: CGFloat, pixelHeight: CGFloat, limitWidth: Int, limitHeight: Int) -> (width: Int, height: Int) {
        let longLimit = CGFloat(max(limitWidth, limitHeight))
        let shortLimit = CGFloat(min(limitWidth, limitHeight))
        let scale = min(1, longLimit / max(pixelWidth, pixelHeight), shortLimit / min(pixelWidth, pixelHeight))
        // H.264 の 4:2:0 は縦横とも偶数でないと符号化できない
        let width = Int(pixelWidth * scale) & ~1
        let height = Int(pixelHeight * scale) & ~1
        return (max(width, 2), max(height, 2))
    }

    /// 送る大きさに見合った平均のビットレート。低遅延のレート制御は予算を超えるとフレームを落とすので、画素数に合わせて増やす。
    public static func bitRate(width: Int, height: Int) -> Int {
        min(max(width * height * 4, 8_000_000), 40_000_000)
    }
}
