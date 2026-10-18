import Foundation

/// Mac で再生中のサウンドのチャンク形式。48kHz・ステレオ・16 ビットのリトルエンディアンで、左右を交互に並べる (無圧縮のまま送ると約 1.5Mbps)。iPad が要求すれば、チャンクごとに Opus にエンコードして送る (`MacAudioEncoder`)。
public enum MacAudio {
    public static let sampleRate = 48_000
    public static let channelCount = 2
    /// 1 回に送る長さ (20ms)。
    public static let chunkFrames = sampleRate / 50

    /// 左右の -1...1 の浮動小数点のサンプルを、送信時の形式にする。範囲外は切り詰める。
    public static func encode(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> Data {
        let frames = min(left.count, right.count)
        var data = Data(count: frames * channelCount * 2)
        data.withUnsafeMutableBytes { raw in
            for index in 0 ..< frames {
                raw.storeBytes(of: sample(left[index]).littleEndian, toByteOffset: index * 4, as: Int16.self)
                raw.storeBytes(of: sample(right[index]).littleEndian, toByteOffset: index * 4 + 2, as: Int16.self)
            }
        }
        return data
    }

    /// 無音のチャンクか。無音の間は送らず、通信と iPad のバッテリーを消費しない。
    public static func isSilent(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0 }
    }

    private static func sample(_ value: Float) -> Int16 {
        PadAudio.int16(value)
    }
}
