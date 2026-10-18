import CoreMedia
import Foundation

public enum VideoCodingError: Error, Equatable {
    case missingParameterSets
    case unsupportedNALUnitHeaderLength(Int32)
    case missingData
    case status(OSStatus)
}

extension VideoFormat {
    static let nalUnitHeaderLength: Int32 = 4

    public init(formatDescription: CMFormatDescription) throws {
        let codec: VideoCodec
        let minimumCount: Int
        switch CMFormatDescriptionGetMediaSubType(formatDescription) {
        case kCMVideoCodecType_H264:
            (codec, minimumCount) = (.h264, 2)
        case kCMVideoCodecType_HEVC:
            (codec, minimumCount) = (.hevc, 3)
        case let subType:
            throw VideoCodingError.status(OSStatus(bitPattern: subType))
        }
        func parameterSet(at index: Int, count: UnsafeMutablePointer<Int>?, headerLength: UnsafeMutablePointer<Int32>?) throws -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = switch codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength
                )
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength
                )
            }
            guard status == noErr else { throw VideoCodingError.status(status) }
            return pointer.map { Data(bytes: $0, count: size) }
        }

        var count = 0
        var headerLength: Int32 = 0
        _ = try parameterSet(at: 0, count: &count, headerLength: &headerLength)
        guard count >= minimumCount else { throw VideoCodingError.missingParameterSets }
        guard headerLength == Self.nalUnitHeaderLength else { throw VideoCodingError.unsupportedNALUnitHeaderLength(headerLength) }
        let parameterSets = try (0 ..< count).map { index in
            guard let data = try parameterSet(at: index, count: nil, headerLength: nil) else { throw VideoCodingError.missingParameterSets }
            return data
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        self.init(codec: codec, width: Int(dimensions.width), height: Int(dimensions.height), parameterSets: parameterSets)
    }

    public func makeFormatDescription() throws -> CMVideoFormatDescription {
        guard parameterSets.count >= (codec == .h264 ? 2 : 3), !parameterSets.contains(where: \.isEmpty) else {
            throw VideoCodingError.missingParameterSets
        }
        // CoreMedia は呼んでいる間だけポインタを読むので、写しを取って呼び終えたら放す
        let buffers = parameterSets.map { data -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = buffer.initialize(from: data)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = parameterSets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = switch codec {
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Self.nalUnitHeaderLength, formatDescriptionOut: &description
            )
        case .hevc:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Self.nalUnitHeaderLength, extensions: nil, formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { throw VideoCodingError.status(status) }
        return description
    }
}

extension VideoFrame {
    public init(sampleBuffer: CMSampleBuffer) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw VideoCodingError.missingData }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoCodingError.status(status) }

        let notSync = sampleBuffer.sampleAttachments.first?[.notSync] as? Bool ?? false
        self.init(isKeyFrame: !notSync, presentationTimeMicros: Self.presentationTimeMicros(of: sampleBuffer.presentationTimeStamp), data: data)
    }

    /// 符号化に渡した時刻を、送るフレームの時刻 (マイクロ秒) にする。
    public static func presentationTimeMicros(of time: CMTime) -> Int64 {
        time.isNumeric ? Int64(time.seconds * 1_000_000) : 0
    }

    /// iPad 側でデコーダに渡すためのサンプルバッファを作る。到着したらすぐ表示させる。
    public func makeSampleBuffer(formatDescription: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw VideoCodingError.status(status) }
        status = data.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoCodingError.status(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationTimeMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw VideoCodingError.status(status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
