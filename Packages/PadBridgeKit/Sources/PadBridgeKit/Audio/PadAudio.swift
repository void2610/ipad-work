import Foundation

/// iPad のマイクから Mac へ送る音声の形式。変換コストと遅延を減らすため、無圧縮の 48kHz・モノラル・16 ビットにする (約 768kbps)。
public enum PadAudio {
    public static let sampleRate = 48_000

    /// 振幅を、画面に表示する音量 (0...1) にする。話し声で見て分かるよう、-50dB〜-10dB を 0〜1 に割り当てる。
    public static func level(peak: Float) -> Float {
        let decibels = 20 * log10(max(peak, 1e-6))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    /// -1...1 の浮動小数点のサンプルを 16 ビットにする。範囲外は切り詰め、NaN は無音にする。
    /// min・max は NaN をそのまま通し、Int16 にするとクラッシュする。Host は Mac のすべてのアプリの音声を読み取るので、どこかのアプリが NaN を出しても落ちないようにする
    public static func int16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return sample.isNaN ? 0 : (sample > 0 ? Int16.max : -Int16.max) }
        return Int16(min(max(sample, -1), 1) * Float(Int16.max))
    }

    /// -1...1 の浮動小数点のサンプルを、送信形式 (16 ビットのリトルエンディアン) にする。範囲外は切り詰める。
    public static func encode(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let value = int16(sample)
                raw.storeBytes(of: value.littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return data
    }
}

/// 届いたサンプルを、再生するまでバッファする。
/// ネットワークのジッターで途切れないよう少しバッファしてから出し始め、バッファしすぎて遅延しないよう、あふれたら古いものから破棄する。
/// ステレオは左右を交互に並べて保持する。数はどれも、フレームではなくサンプルの数で数える。
public struct PCMJitterBuffer: Sendable {
    public let startThreshold: Int
    public let channelCount: Int
    // あふれたときに、再生開始時のバッファ量まで一気に減らすか。1 つずつ破棄すると、輻輳して一度に届いた分の遅延がそのまま残る
    private let trimsOnOverflow: Bool
    private var storage: [Int16]
    private var readIndex = 0
    public private(set) var count = 0
    /// これまでに書き込んだサンプルの数。どこまで再生し終えたかを `consumed` と比べて確認する。
    public private(set) var written = 0
    /// これまでに再生したサンプルと、あふれて破棄したサンプルの数。
    public private(set) var consumed = 0
    /// 再生中にサンプルが足りなくなり、途切れた回数。
    public private(set) var underruns = 0
    private var isPlaying = false

    /// `capacity` と `startThreshold` はフレームの数で渡す。
    /// `trimsOnOverflow` は、遅延を詰めることが途切れより大事な音声 (Mac のサウンド) で使う。iPad の声は Typeless に全部聞かせたいので使わない。
    public init(capacity: Int, startThreshold: Int, channelCount: Int = 1, trimsOnOverflow: Bool = false) {
        storage = [Int16](repeating: 0, count: capacity * channelCount)
        self.startThreshold = min(startThreshold, capacity) * channelCount
        self.channelCount = channelCount
        self.trimsOnOverflow = trimsOnOverflow
    }

    public mutating func write(_ data: Data) {
        // フレームの途中で切れた分は破棄し、左右がずれないようにする
        let frameBytes = 2 * channelCount
        let usable = data.count / frameBytes * frameBytes
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: usable, by: 2) {
                append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            }
        }
    }

    /// -1...1 の浮動小数点のサンプルを書き込む。メモリを確保しないので、オーディオのスレッドから呼べる。
    public mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            append(PadAudio.int16(sample))
        }
    }

    private mutating func append(_ sample: Int16) {
        if count == storage.count {
            // 書き込みはフレーム単位なので、ここでの数とバッファ量はどちらもチャンネル数の倍数で、破棄しても左右はずれない
            let dropped = trimsOnOverflow ? max(count - startThreshold, 1) : 1
            readIndex = (readIndex + dropped) % storage.count
            count -= dropped
            consumed += dropped
        }
        storage[(readIndex + count) % storage.count] = sample
        count += 1
        written += 1
    }

    /// `output` を埋める。まだバッファが溜まっていないときや足りない分は無音にする。
    public mutating func read(into output: UnsafeMutableBufferPointer<Float>) {
        beginIfFilled()
        var ranOut = false
        for index in output.indices {
            guard isPlaying, count > 0 else {
                ranOut = ranOut || isPlaying
                output[index] = 0
                continue
            }
            output[index] = pop()
        }
        endRead(ranOut: ranOut)
    }

    /// ステレオでバッファしたサンプルを、左右に分けて埋める。
    public mutating func read(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        beginIfFilled()
        var ranOut = false
        for index in 0 ..< min(left.count, right.count) {
            guard isPlaying, count >= 2 else {
                ranOut = ranOut || isPlaying
                left[index] = 0
                right[index] = 0
                continue
            }
            left[index] = pop()
            right[index] = pop()
        }
        endRead(ranOut: ranOut)
    }

    private mutating func beginIfFilled() {
        if !isPlaying, count >= startThreshold {
            isPlaying = true
        }
    }

    private mutating func pop() -> Float {
        let sample = Float(storage[readIndex]) / Float(Int16.max)
        readIndex = (readIndex + 1) % storage.count
        count -= 1
        consumed += 1
        return sample
    }

    private mutating func endRead(ranOut: Bool) {
        if ranOut {
            underruns += 1
        }
        // 途切れたら、またバッファが溜まるまで待つ
        if count < channelCount {
            isPlaying = false
        }
    }

    /// もう続きが届かないので、バッファが溜まりきっていなくても残りの再生を始める。
    /// 再生開始時のバッファ量に届かないまま停止されると、残りは再生されないまま、再生完了を待つ側がタイムアウトまで待ち続ける。
    public mutating func playRemaining() {
        if count >= channelCount {
            isPlaying = true
        }
    }

    /// バッファしているサンプルを破棄し、カウントし直す。
    public mutating func removeAll() {
        readIndex = 0
        count = 0
        written = 0
        consumed = 0
        underruns = 0
        isPlaying = false
    }
}
