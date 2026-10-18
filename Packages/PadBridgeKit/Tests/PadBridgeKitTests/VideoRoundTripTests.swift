import CoreMedia
import CoreVideo
import Foundation
@testable import PadBridgeKit
import Synchronization
import Testing
import VideoToolbox

#if os(macOS)
// エンコードするのは Mac の Host だけ。iOS シミュレータには低遅延のエンコーダがなく、作成できない (-12908)
// 低遅延のエンコーダを複数同時に作成すると、VTCompressionSessionCreate から戻らなくなった。Host も 1 つずつしか作らないので、順に試す
@Suite(.serialized)
struct VideoRoundTripTests {
    /// Mac 側のエンコード → 通信路のシリアライズ → iPad 側のサンプルバッファ化、を経てデコードできることを確認する。
    /// 実際に送るサイズ (外部ディスプレイの 1920x1080、内蔵ディスプレイを縮小した 2360x1532、縦置きディスプレイの 1080x1920 と 1326x2360) で、Host と同じビットレートにする。
    /// 4Mbps に固定すると、大きなディスプレイでは 10 フレーム中 1〜2 フレームが低遅延のレート制御で破棄された。
    @Test(arguments: [VideoCodec.h264, .hevc], [(640, 400), (1920, 1080), (2360, 1532), (1080, 1920), (1326, 2360)])
    func encodedFramesDecodeAfterWireRoundTrip(codec: VideoCodec, size: (width: Int, height: Int)) async throws {
        let (width, height) = size
        let received = Mutex<[(VideoFormat?, VideoFrame)]>([])
        let encoder = try VideoEncoder(codec: codec, width: width, height: height, averageBitRate: CaptureSize.bitRate(width: width, height: height), frameRate: 60) { format, frame in
            received.withLock { $0.append((format, frame)) }
        }
        for index in 0 ..< 10 {
            let pixelBuffer = try makePixelBuffer(width: width, height: height, luma: UInt8(20 * index))
            encoder.encode(pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 60), forceKeyFrame: index == 0)
        }
        encoder.flush()

        let outputs = received.withLock { $0 }
        #expect(outputs.count == 10)
        let firstFormat = try #require(outputs.first?.0)
        #expect(outputs.first?.1.isKeyFrame == true)
        #expect(firstFormat.width == width && firstFormat.height == height)
        #expect(firstFormat.codec == codec)
        #expect(firstFormat.parameterSets.count == (codec == .hevc ? 3 : 2))

        let wireFormat = try roundTrip(.videoFormat(firstFormat))
        guard case let .videoFormat(format) = wireFormat else { Issue.record("映像フォーマットに復元できない"); return }
        let description = try format.makeFormatDescription()
        let decoder = try Decoder(formatDescription: description)
        for (_, frame) in outputs {
            guard case let .videoFrame(wireFrame) = try roundTrip(.videoFrame(frame)) else { Issue.record("フレームに復元できない"); return }
            try decoder.decode(wireFrame.makeSampleBuffer(formatDescription: description))
        }
        #expect(decoder.decodedSizes.count == 10)
        #expect(decoder.decodedSizes.allSatisfy { $0 == CGSize(width: width, height: height) })
    }

    /// 回線が輻輳したときに、エンコードを続けたままビットレートを下げると、フレームが小さくなる。
    @Test(arguments: [VideoCodec.h264, .hevc])
    func loweringBitRateShrinksFrames(codec: VideoCodec) throws {
        let (width, height) = (1280, 720)
        let sizes = Mutex<[Int]>([])
        let encoder = try VideoEncoder(codec: codec, width: width, height: height, averageBitRate: 20_000_000, frameRate: 60) { _, frame in
            sizes.withLock { $0.append(frame.data.count) }
        }
        // ランダムノイズにすると、エンコーダは細部を捨てて灰色にし、どちらでも数百バイトになる。8x8 の濃淡のブロックを毎フレーム入れ替え、20 Mbps では収まり 2 Mbps では収まらない量にする
        for index in 0 ..< 60 {
            if index == 30 {
                encoder.setAverageBitRate(2_000_000)
            }
            let pixelBuffer = try makePixelBuffer(width: width, height: height) { x, y in
                var hash = UInt32(x / 8) &* 73_856_093 ^ UInt32(y / 8) &* 19_349_663 ^ UInt32(index) &* 83_492_791
                hash ^= hash >> 13
                hash = hash &* 1_274_126_177
                return UInt8(truncatingIfNeeded: hash >> 24)
            }
            encoder.encode(pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 60), forceKeyFrame: index == 0)
        }
        encoder.flush()
        let outputs = sizes.withLock { $0 }
        // 予算を超える分は低遅延のレート制御がフレームを破棄する (このテストパターンでは 60 フレーム中 49〜50 フレームが出力された)
        try #require(outputs.count >= 40)
        let before = outputs[10 ..< 25].reduce(0, +) / 15
        let after = outputs.suffix(10).reduce(0, +) / 10
        // 1 フレームあたりの予算は約 42KB から約 4KB に減る。このテストパターンでは 40KB ほどから 8〜12KB に縮小した
        #expect(after * 3 < before, "引き下げ前 \(before) バイト、引き下げ後 \(after) バイト")
    }

    private func roundTrip(_ message: WireMessage) throws -> WireMessage {
        let encoded = try message.encoded()
        return try WireMessage(type: encoded.type, payload: encoded.payload)
    }

    private func makePixelBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        try makePixelBuffer(width: width, height: height) { _, _ in luma }
    }

    private func makePixelBuffer(width: Int, height: Int, luma: (_ x: Int, _ y: Int) -> UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
        let buffer = try #require(pixelBuffer, "CVPixelBufferCreate: \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0 ..< CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            guard let base else { continue }
            if plane == 0 {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for offset in 0 ..< size {
                    bytes[offset] = luma(offset % bytesPerRow, offset / bytesPerRow)
                }
            } else {
                memset(base, 128, size)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private final class Decoder {
        private let session: VTDecompressionSession
        private(set) var decodedSizes: [CGSize] = []

        init(formatDescription: CMVideoFormatDescription) throws {
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: nil,
                imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
            )
            self.session = try #require(session, "VTDecompressionSessionCreate: \(status)")
        }

        func decode(_ sampleBuffer: CMSampleBuffer) throws {
            let size = Mutex<CGSize?>(nil)
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                if status == noErr, let imageBuffer {
                    size.withLock { $0 = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer)) }
                }
            }
            #expect(status == noErr)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if let decoded = size.withLock({ $0 }) { decodedSizes.append(decoded) }
        }
    }
}
#endif
