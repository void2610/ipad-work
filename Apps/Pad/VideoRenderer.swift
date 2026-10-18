import AVFoundation
import CoreMedia
import PadBridgeKit

/// 受信した H.264 を表示レイヤに流す。`handle` は映像用キュー上でのみ呼ぶ。
nonisolated final class VideoRenderer: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// 映像の開始前に設定しておく。
    var onNeedsKeyFrame: (@Sendable () -> Void)?
    var onVideoSizeChange: (@Sendable (CGSize) -> Void)?
    /// 受信したフレームに写っている Mac のディスプレイの範囲が変わったときに呼ぶ。
    var onRegionChange: (@Sendable (VideoRegion) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyFrame = true
    private var region = VideoRegion.full

    /// 映像の接続を再確立するとき、前の接続の残りを破棄してキーフレームから描き直す。
    func reset() {
        displayLayer.sampleBufferRenderer.flush()
        formatDescription = nil
        waitingForKeyFrame = true
        region = .full
        onRegionChange?(.full)
    }

    func handle(_ message: WireMessage) {
        switch message {
        case let .videoFormat(format):
            formatDescription = try? format.makeFormatDescription()
            onVideoSizeChange?(CGSize(width: format.width, height: format.height))
        case let .videoFrame(frame):
            enqueue(frame)
        case .control, .audio, .macAudio, .macAudioOpus:
            break
        }
    }

    private func enqueue(_ frame: VideoFrame) {
        let renderer = displayLayer.sampleBufferRenderer
        // バックグラウンドに移ると表示レイヤが壊れる。フォアグラウンドに戻ったら破棄して、キーフレームから描き直す
        if renderer.status == .failed {
            renderer.flush()
            restartFromKeyFrame()
        }
        if waitingForKeyFrame, !frame.isKeyFrame { return }
        guard let formatDescription, let sampleBuffer = try? frame.makeSampleBuffer(formatDescription: formatDescription) else {
            restartFromKeyFrame()
            return
        }
        waitingForKeyFrame = false
        if frame.region != region {
            region = frame.region
            onRegionChange?(frame.region)
        }
        renderer.enqueue(sampleBuffer)
    }

    private func restartFromKeyFrame() {
        guard !waitingForKeyFrame else { return }
        waitingForKeyFrame = true
        onNeedsKeyFrame?()
    }
}
