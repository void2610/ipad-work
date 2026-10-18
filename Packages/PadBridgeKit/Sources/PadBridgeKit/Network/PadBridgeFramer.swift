import Foundation
import Network

struct FrameHeader {
    static let size = 8
    // 不正な長さを受け取ったときに巨大なバッファを確保しないための上限
    static let maxPayloadLength: UInt32 = 32 * 1024 * 1024

    var type: UInt32
    var length: UInt32

    init(type: UInt32, length: UInt32) {
        self.type = type
        self.length = length
    }

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        type = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        length = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }

    var encoded: Data {
        var writer = ByteWriter()
        writer.write(type)
        writer.write(length)
        return writer.data
    }
}

final class PadBridgeFramer: NWProtocolFramerImplementation {
    static let label = "PadBridge"
    static let definition = NWProtocolFramer.Definition(implementation: PadBridgeFramer.self)

    init(framer _: NWProtocolFramer.Instance) {}

    func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    func wakeup(framer _: NWProtocolFramer.Instance) {}

    func stop(framer _: NWProtocolFramer.Instance) -> Bool {
        true
    }

    func cleanup(framer _: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete _: Bool) {
        let header = FrameHeader(type: message.padBridgeMessageType, length: UInt32(messageLength))
        framer.writeOutput(data: header.encoded)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var header: FrameHeader?
            let parsed = framer.parseInput(minimumIncompleteLength: FrameHeader.size, maximumLength: FrameHeader.size) { buffer, _ in
                guard let buffer, buffer.count >= FrameHeader.size else { return 0 }
                header = FrameHeader(buffer)
                return FrameHeader.size
            }
            guard parsed, let header else { return FrameHeader.size }
            guard header.length <= FrameHeader.maxPayloadLength else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(padBridgeMessageType: header.type)
            guard framer.deliverInputNoCopy(length: Int(header.length), message: message, isComplete: true) else {
                return 0
            }
        }
    }
}

extension NWProtocolFramer.Message {
    convenience init(padBridgeMessageType: UInt32) {
        self.init(definition: PadBridgeFramer.definition)
        self["type"] = padBridgeMessageType
    }

    var padBridgeMessageType: UInt32 {
        self["type"] as? UInt32 ?? 0
    }
}
