import CoreMedia
import CoreVideo
import Foundation
@testable import PadBridgeKit
import Synchronization
import Testing
import VideoToolbox

struct VideoRoundTripTests {
    /// Mac 側の符号化 → 通信路の直列化 → iPad 側のサンプルバッファ化、を経て復号できることを確かめる。
    /// 実際に送る大きさ (外部ディスプレイの 1920x1080、内蔵の画面を縮めた 2360x1532、縦に置いたディスプレイの 1080x1920 と 1326x2360) で、Host と同じビットレートにする。
    /// 4Mbps に決め打ちすると、大きな画面では 10 フレーム中 1〜2 フレームを低遅延のレート制御が落とした。
    @Test(arguments: [(640, 400), (1920, 1080), (2360, 1532), (1080, 1920), (1326, 2360)])
    func encodedFramesDecodeAfterWireRoundTrip(width: Int, height: Int) async throws {
        let received = Mutex<[(VideoFormat?, VideoFrame)]>([])
        let encoder = try H264Encoder(width: width, height: height, averageBitRate: CaptureSize.bitRate(width: width, height: height), frameRate: 60) { format, frame in
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

        let wireFormat = try roundTrip(.videoFormat(firstFormat))
        guard case let .videoFormat(format) = wireFormat else { Issue.record("映像フォーマットに戻らない"); return }
        let description = try format.makeFormatDescription()
        let decoder = try Decoder(formatDescription: description)
        for (_, frame) in outputs {
            guard case let .videoFrame(wireFrame) = try roundTrip(.videoFrame(frame)) else { Issue.record("フレームに戻らない"); return }
            try decoder.decode(wireFrame.makeSampleBuffer(formatDescription: description))
        }
        #expect(decoder.decodedSizes.count == 10)
        #expect(decoder.decodedSizes.allSatisfy { $0 == CGSize(width: width, height: height) })
    }

    private func roundTrip(_ message: WireMessage) throws -> WireMessage {
        let encoded = try message.encoded()
        return try WireMessage(type: encoded.type, payload: encoded.payload)
    }

    private func makePixelBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
        let buffer = try #require(pixelBuffer, "CVPixelBufferCreate: \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0 ..< CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? Int32(luma) : 128, size)
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
