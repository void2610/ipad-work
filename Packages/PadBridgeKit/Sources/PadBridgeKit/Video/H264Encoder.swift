import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 画面転送用の低遅延 H.264 エンコーダ。`encode` は同じスレッドから順に呼ぶこと。
public final class H264Encoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (_ format: VideoFormat?, _ frame: VideoFrame) -> Void

    private let session: VTCompressionSession
    private let output: OutputHandler

    public init(width: Int, height: Int, averageBitRate: Int, frameRate: Int, output: @escaping OutputHandler) throws {
        var session: VTCompressionSession?
        // 低遅延レート制御は、フレームの並べ替えをせず 1 フレームずつ即座に出力させるために使う
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoCodingError.status(status) }
        self.session = session
        self.output = output

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            // 低遅延レート制御が対応するのは Constrained 系のプロファイルだけ
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: averageBitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            // 画面が止まっている間はフレームが来ないので、時間で区切って定期的に回復点を作る
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 5,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyFrame: Bool) {
        let frameProperties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [output] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let frame = try? VideoFrame(sampleBuffer: sampleBuffer) else { return }
            var format: VideoFormat?
            if frame.isKeyFrame, let description = sampleBuffer.formatDescription {
                format = try? VideoFormat(formatDescription: description)
            }
            output(format, frame)
        }
    }

    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }
}
