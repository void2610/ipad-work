import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 画面転送用の低遅延エンコーダ。`encode` は同じスレッドから順に呼ぶこと。
public final class VideoEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (_ format: VideoFormat?, _ frame: VideoFrame) -> Void

    public let codec: VideoCodec
    private let session: VTCompressionSession
    private let output: OutputHandler

    public init(codec: VideoCodec, width: Int, height: Int, averageBitRate: Int, frameRate: Int, keyFrameInterval: TimeInterval = 30, output: @escaping OutputHandler) throws {
        var session: VTCompressionSession?
        // 低遅延レート制御は、フレームの並べ替えをせず 1 フレームずつ即座に出力させるために使う
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoCodingError.status(status) }
        self.codec = codec
        self.session = session
        self.output = output

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            // 低遅延レート制御が対応するのは、H.264 では Constrained 系のプロファイルだけ
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: averageBitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            // キーフレームは iPad の要求時に作る (受信確認付きの TCP で、途中で失われるフレームはない)。大きなキーフレームは遅い回線で遅延のピークになるので、定期のものは念のため 30 秒ごとにとどめる
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyFrameInterval,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// `region` は、このフレームに写っている Mac のディスプレイの範囲。受信側はそれに合わせて配置する。
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyFrame: Bool, region: VideoRegion = .full) {
        let frameProperties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [output] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, var frame = try? VideoFrame(sampleBuffer: sampleBuffer) else { return }
            frame.region = region
            var format: VideoFormat?
            if frame.isKeyFrame, let description = sampleBuffer.formatDescription {
                format = try? VideoFormat(formatDescription: description)
            }
            output(format, frame)
        }
    }

    /// エンコードを続けたまま、平均ビットレートを変える。`encode` と同じスレッドから呼ぶ。
    public func setAverageBitRate(_ bitRate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
    }

    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }
}
