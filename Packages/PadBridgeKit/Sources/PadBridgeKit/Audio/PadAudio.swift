import Foundation

/// iPad のマイクから Mac へ送る音の形式。変換の手間と遅れを減らすため、圧縮しない 48kHz・モノラル・16 ビットにする (約 768kbps)。
public enum PadAudio {
    public static let sampleRate = 48_000

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

/// iPad から届いた音を、Mac で鳴らすまでためておく。
/// ネットワークの揺れで途切れないよう少したまってから出し始め、ためすぎて遅れないよう、あふれたら古い音から捨てる。
public struct PCMJitterBuffer: Sendable {
    public let startThreshold: Int
    private var storage: [Int16]
    private var readIndex = 0
    public private(set) var count = 0
    private var isPlaying = false

    public init(capacity: Int, startThreshold: Int) {
        storage = [Int16](repeating: 0, count: capacity)
        self.startThreshold = min(startThreshold, capacity)
    }

    public mutating func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                if count == storage.count {
                    readIndex = (readIndex + 1) % storage.count
                    count -= 1
                }
                storage[(readIndex + count) % storage.count] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                count += 1
            }
        }
    }

    /// `output` を埋める。まだたまっていないときや足りない分は無音にする。
    public mutating func read(into output: UnsafeMutableBufferPointer<Float>) {
        if !isPlaying, count >= startThreshold {
            isPlaying = true
        }
        for index in output.indices {
            guard isPlaying, count > 0 else {
                output[index] = 0
                continue
            }
            output[index] = Float(storage[readIndex]) / Float(Int16.max)
            readIndex = (readIndex + 1) % storage.count
            count -= 1
        }
        // 途切れたら、またたまるまで待つ
        if count == 0 {
            isPlaying = false
        }
    }

    public mutating func removeAll() {
        readIndex = 0
        count = 0
        isPlaying = false
    }
}
