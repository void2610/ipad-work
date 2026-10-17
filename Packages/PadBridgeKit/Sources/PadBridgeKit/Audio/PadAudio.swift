import Foundation

/// iPad のマイクから Mac へ送る音の形式。変換の手間と遅れを減らすため、圧縮しない 48kHz・モノラル・16 ビットにする (約 768kbps)。
public enum PadAudio {
    public static let sampleRate = 48_000

    /// 振れ幅を、画面に出す声の大きさ (0...1) にする。話し声で見て分かるよう、-50dB〜-10dB を 0〜1 に割り当てる。
    public static func level(peak: Float) -> Float {
        let decibels = 20 * log10(max(peak, 1e-6))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    /// -1...1 の浮動小数の音を、送るときの形 (16 ビットのリトルエンディアン) にする。範囲外は切り詰める。
    public static func encode(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let clamped = min(max(sample, -1), 1)
                let value = Int16(clamped * Float(Int16.max))
                raw.storeBytes(of: value.littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return data
    }
}

/// 届いた音を、鳴らすまでためておく。
/// ネットワークの揺れで途切れないよう少したまってから出し始め、ためすぎて遅れないよう、あふれたら古い音から捨てる。
/// ステレオは左右を交互に並べてためる。数はどれも、フレームではなく音の数で数える。
public struct PCMJitterBuffer: Sendable {
    public let startThreshold: Int
    public let channelCount: Int
    private var storage: [Int16]
    private var readIndex = 0
    public private(set) var count = 0
    /// これまでに書き込んだ音の数。どこまで鳴らし終えたかを `consumed` と比べて見る。
    public private(set) var written = 0
    /// これまでに鳴らした音と、あふれて捨てた音の数。
    public private(set) var consumed = 0
    /// 鳴らしている途中で音が足りなくなり、途切れた回数。
    public private(set) var underruns = 0
    private var isPlaying = false

    /// `capacity` と `startThreshold` はフレームの数で渡す。
    public init(capacity: Int, startThreshold: Int, channelCount: Int = 1) {
        storage = [Int16](repeating: 0, count: capacity * channelCount)
        self.startThreshold = min(startThreshold, capacity) * channelCount
        self.channelCount = channelCount
    }

    public mutating func write(_ data: Data) {
        // フレームの途中で切れた分は捨て、左右がずれないようにする
        let frameBytes = 2 * channelCount
        let usable = data.count / frameBytes * frameBytes
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: usable, by: 2) {
                append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            }
        }
    }

    /// -1...1 の浮動小数の音を書き込む。メモリを確保しないので、オーディオのスレッドから呼べる。
    public mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            append(Int16(min(max(sample, -1), 1) * Float(Int16.max)))
        }
    }

    private mutating func append(_ sample: Int16) {
        if count == storage.count {
            readIndex = (readIndex + 1) % storage.count
            count -= 1
            consumed += 1
        }
        storage[(readIndex + count) % storage.count] = sample
        count += 1
        written += 1
    }

    /// `output` を埋める。まだたまっていないときや足りない分は無音にする。
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

    /// ステレオでためた音を、左右に分けて埋める。
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
        // 途切れたら、またたまるまで待つ
        if count < channelCount {
            isPlaying = false
        }
    }

    /// ためている音を捨て、数え直す。
    public mutating func removeAll() {
        readIndex = 0
        count = 0
        written = 0
        consumed = 0
        underruns = 0
        isPlaying = false
    }
}
