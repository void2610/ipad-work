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
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, count >= 2 else { throw VideoCodingError.missingParameterSets }
        guard headerLength == Self.nalUnitHeaderLength else { throw VideoCodingError.unsupportedNALUnitHeaderLength(headerLength) }

        func parameterSet(at index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { throw VideoCodingError.status(status) }
            return Data(bytes: pointer, count: size)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        try self.init(width: Int(dimensions.width), height: Int(dimensions.height), sps: parameterSet(at: 0), pps: parameterSet(at: 1))
    }

    public func makeFormatDescription() throws -> CMVideoFormatDescription {
        try sps.withUnsafeBytes { spsBuffer in
            try pps.withUnsafeBytes { ppsBuffer in
                guard let spsPointer = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPointer = ppsBuffer.bindMemory(to: UInt8.self).baseAddress
                else { throw VideoCodingError.missingParameterSets }
                var description: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [spsPointer, ppsPointer],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: Self.nalUnitHeaderLength,
                    formatDescriptionOut: &description
                )
                guard status == noErr, let description else { throw VideoCodingError.status(status) }
                return description
            }
        }
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
        let time = sampleBuffer.presentationTimeStamp
        self.init(isKeyFrame: !notSync, presentationTimeMicros: time.isNumeric ? Int64(time.seconds * 1_000_000) : 0, data: data)
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
