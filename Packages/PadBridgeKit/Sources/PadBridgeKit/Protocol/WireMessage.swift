import Foundation

public struct VideoFormat: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var sps: Data
    public var pps: Data

    public init(width: Int, height: Int, sps: Data, pps: Data) {
        self.width = width
        self.height = height
        self.sps = sps
        self.pps = pps
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

    enum Kind: UInt32 {
        case control = 1
        case videoFormat = 2
        case videoFrame = 3
        case audio = 4
    }

    public func encoded() throws -> (type: UInt32, payload: Data) {
        switch self {
        case let .control(message):
            return (Kind.control.rawValue, try JSONEncoder().encode(message))
        case let .videoFormat(format):
            var writer = ByteWriter()
            writer.write(UInt32(format.width))
            writer.write(UInt32(format.height))
            writer.writeLengthPrefixed(format.sps)
            writer.writeLengthPrefixed(format.pps)
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
        }
    }

    public init(type: UInt32, payload: Data) throws {
        switch Kind(rawValue: type) {
        case .control:
            self = try .control(JSONDecoder().decode(ControlMessage.self, from: payload))
        case .videoFormat:
            var reader = ByteReader(payload)
            let width = try Int(reader.read(UInt32.self))
            let height = try Int(reader.read(UInt32.self))
            let sps = try reader.readLengthPrefixed()
            let pps = try reader.readLengthPrefixed()
            self = .videoFormat(VideoFormat(width: width, height: height, sps: sps, pps: pps))
        case .videoFrame:
            var reader = ByteReader(payload)
            let isKeyFrame = try reader.read(UInt8.self) != 0
            let presentationTime = try reader.read(Int64.self)
            let values = try (0 ..< 4).map { _ in try Double(bitPattern: reader.read(UInt64.self)) }
            let region = VideoRegion(x: values[0], y: values[1], width: values[2], height: values[3])
            self = .videoFrame(VideoFrame(isKeyFrame: isKeyFrame, presentationTimeMicros: presentationTime, region: region, data: reader.readRemaining()))
        case .audio:
            self = .audio(payload)
        case nil:
            throw WireError.unknownMessageType(type)
        }
    }
}
