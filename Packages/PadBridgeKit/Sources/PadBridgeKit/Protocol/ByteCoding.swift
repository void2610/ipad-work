import Foundation

public enum WireError: Error, Equatable {
    case truncated
    case unknownMessageType(UInt32)
    case unknownVideoCodec(UInt8)
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeLengthPrefixed(_ bytes: Data) {
        write(UInt32(bytes.count))
        write(bytes)
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try readBytes(count: MemoryLayout<T>.size)
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
        return T(bigEndian: value)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw WireError.truncated }
        defer { offset += count }
        return Data(data[offset ..< offset + count])
    }

    mutating func readLengthPrefixed() throws -> Data {
        try readBytes(count: Int(read(UInt32.self)))
    }

    mutating func readRemaining() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}
