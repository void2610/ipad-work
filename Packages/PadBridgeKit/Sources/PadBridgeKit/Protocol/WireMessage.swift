import Foundation

/// 映像の符号化の方式。
public enum VideoCodec: UInt8, Sendable {
    case h264 = 0
    /// 同じビットレートでも文字がにじみにくいので、Mac で作れればこちらを使う。
    case hevc = 1
}

public struct VideoFormat: Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// 復号に要るパラメータセット。H.264 は SPS・PPS、HEVC は VPS・SPS・PPS の順。
    public var parameterSets: [Data]

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }
}

/// H.264 の 1 フレーム。`data` は 4 バイト長プレフィクスの AVCC 形式。
public struct VideoFrame: Sendable, Equatable {
    public var isKeyFrame: Bool
    public var presentationTimeMicros: Int64
    /// このフレームに写っている、Mac の画面の範囲。
    public var region: VideoRegion
    public var data: Data

    public init(isKeyFrame: Bool, presentationTimeMicros: Int64, region: VideoRegion = .full, data: Data) {
        self.isKeyFrame = isKeyFrame
        self.presentationTimeMicros = presentationTimeMicros
        self.region = region
        self.data = data
    }
}

public enum WireMessage: Sendable, Equatable {
    case control(ControlMessage)
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrame)
    /// iPad のマイクの音。形式は `PadAudio` (48kHz・モノラル・16 ビットのリトルエンディアン)。
    case audio(Data)
    /// Mac で鳴っている音。形式は `MacAudio` (48kHz・ステレオ・16 ビットのリトルエンディアン)。
    case macAudio(Data)
    /// Mac で鳴っている音を Opus にした 1 パケット (20ms)。iPad が `macAudioCodec(.opus)` で求めたときだけ送る。
    case macAudioOpus(Data)

    enum Kind: UInt32 {
        case control = 1
        case videoFormat = 2
        case videoFrame = 3
        case audio = 4
        case macAudio = 5
        case macAudioOpus = 6
    }

    public func encoded() throws -> (type: UInt32, payload: Data) {
        switch self {
        case let .control(message):
            return (Kind.control.rawValue, try JSONEncoder().encode(message))
        case let .videoFormat(format):
            var writer = ByteWriter()
            writer.write(format.codec.rawValue)
            writer.write(UInt32(format.width))
            writer.write(UInt32(format.height))
            writer.write(UInt8(format.parameterSets.count))
            for parameterSet in format.parameterSets {
                writer.writeLengthPrefixed(parameterSet)
            }
            return (Kind.videoFormat.rawValue, writer.data)
        case let .videoFrame(frame):
            var writer = ByteWriter()
            writer.write(UInt8(frame.isKeyFrame ? 1 : 0))
            writer.write(frame.presentationTimeMicros)
            for value in [frame.region.x, frame.region.y, frame.region.width, frame.region.height] {
                writer.write(value.bitPattern)
            }
            writer.write(frame.data)
            return (Kind.videoFrame.rawValue, writer.data)
        case let .audio(samples):
            return (Kind.audio.rawValue, samples)
        case let .macAudio(samples):
            return (Kind.macAudio.rawValue, samples)
        case let .macAudioOpus(packet):
            return (Kind.macAudioOpus.rawValue, packet)
        }
    }

    public init(type: UInt32, payload: Data) throws {
        switch Kind(rawValue: type) {
        case .control:
            self = try .control(JSONDecoder().decode(ControlMessage.self, from: payload))
        case .videoFormat:
            var reader = ByteReader(payload)
            let codecValue = try reader.read(UInt8.self)
            guard let codec = VideoCodec(rawValue: codecValue) else { throw WireError.unknownVideoCodec(codecValue) }
            let width = try Int(reader.read(UInt32.self))
            let height = try Int(reader.read(UInt32.self))
            let count = try Int(reader.read(UInt8.self))
            let parameterSets = try (0 ..< count).map { _ in try reader.readLengthPrefixed() }
            self = .videoFormat(VideoFormat(codec: codec, width: width, height: height, parameterSets: parameterSets))
        case .videoFrame:
            var reader = ByteReader(payload)
            let isKeyFrame = try reader.read(UInt8.self) != 0
            let presentationTime = try reader.read(Int64.self)
            let values = try (0 ..< 4).map { _ in try Double(bitPattern: reader.read(UInt64.self)) }
            let region = VideoRegion(x: values[0], y: values[1], width: values[2], height: values[3])
            self = .videoFrame(VideoFrame(isKeyFrame: isKeyFrame, presentationTimeMicros: presentationTime, region: region, data: reader.readRemaining()))
        case .audio:
            self = .audio(payload)
        case .macAudio:
            self = .macAudio(payload)
        case .macAudioOpus:
            self = .macAudioOpus(payload)
        case nil:
            throw WireError.unknownMessageType(type)
        }
    }
}
