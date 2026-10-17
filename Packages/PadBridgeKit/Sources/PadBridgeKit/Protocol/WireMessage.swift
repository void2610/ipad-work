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
    public var data: Data

    public init(isKeyFrame: Bool, presentationTimeMicros: Int64, data: Data) {
        self.isKeyFrame = isKeyFrame
        self.presentationTimeMicros = presentationTimeMicros
        self.data = data
    }
}

public enum WireMessage: Sendable, Equatable {
    case control(ControlMessage)
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrame)

    enum Kind: UInt32 {
        case control = 1
        case videoFormat = 2
        case videoFrame = 3
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
            writer.write(frame.data)
            return (Kind.videoFrame.rawValue, writer.data)
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
            self = .videoFrame(VideoFrame(isKeyFrame: isKeyFrame, presentationTimeMicros: presentationTime, data: reader.readRemaining()))
        case nil:
            throw WireError.unknownMessageType(type)
        }
    }
}
