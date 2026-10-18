@preconcurrency import AVFAudio
import Foundation

extension MacAudio {
    /// Mac の音を送る形式。iPad が `opus` を求めたときだけ Opus で送り、知らない古い iPad アプリや Mac とは無圧縮のままやり取りする。
    public enum Codec: String, Codable, Sendable {
        case pcm
        case opus
    }

    /// 無圧縮の形 (左右を交互に並べた 16 ビット)。
    static func makePCMFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: AVAudioChannelCount(channelCount), interleaved: true)
    }

    /// 1 パケットを 1 つの塊 (20ms) にした Opus。
    static func makeOpusFormat() -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(chunkFrames), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)
    }
}

/// Mac の音の塊を Opus にする。無圧縮 (約 1.5 Mbps) だと、遅い回線で映像の取り分を削り、届くまでの遅れもたまる。
/// 1 つのキューから順に呼ぶ。
public final class MacAudioEncoder: @unchecked Sendable {
    /// 音楽でも聞き分けにくい、ステレオの Opus のビットレート。
    public static let bitRate = 128_000

    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat

    public init?() {
        guard let pcmFormat = MacAudio.makePCMFormat(), let opusFormat = MacAudio.makeOpusFormat(),
              let converter = AVAudioConverter(from: pcmFormat, to: opusFormat)
        else { return nil }
        converter.bitRate = Self.bitRate
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.opusFormat = opusFormat
    }

    /// 送る形の塊 (`MacAudio.chunkFrames` フレーム) を Opus のパケットにする。ふつうは 1 つ返る。
    public func encode(_ chunk: Data) -> [Data] {
        let frames = chunk.count / (MacAudio.channelCount * 2)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = input.int16ChannelData
        else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(samples[0], base, frames * MacAudio.channelCount * 2)
        }
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 4, maximumPacketSize: max(converter.maximumOutputPacketSize, 1))
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.packetCount > 0, let descriptions = output.packetDescriptions else { return [] }
        return (0 ..< Int(output.packetCount)).map { index in
            let description = descriptions[index]
            return Data(bytes: output.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize))
        }
    }
}

/// iPad 側で、Opus のパケットを送る形 (左右を交互に並べた 16 ビット) に戻す。1 つのキューから順に呼ぶ。
public final class MacAudioDecoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat

    public init?() {
        guard let pcmFormat = MacAudio.makePCMFormat(), let opusFormat = MacAudio.makeOpusFormat(),
              let converter = AVAudioConverter(from: opusFormat, to: pcmFormat)
        else { return nil }
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.opusFormat = opusFormat
    }

    public func decode(_ packet: Data) -> Data? {
        guard !packet.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(input.data, base, packet.count)
        }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        // 1 パケットは 20ms だが、復号器がためた分を一緒に出しても収まるようにする
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(MacAudio.chunkFrames * 2)) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MacAudio.channelCount * 2)
    }
}
