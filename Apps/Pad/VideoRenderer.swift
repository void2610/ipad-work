import AVFoundation
import CoreMedia
import PadBridgeKit

/// 届いた H.264 を表示レイヤに流す。`handle` は映像用キューの上でだけ呼ぶ。
nonisolated final class VideoRenderer: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// 映像を始める前に設定しておく。
    var onNeedsKeyFrame: (@Sendable () -> Void)?
    var onVideoSizeChange: (@Sendable (CGSize) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyFrame = true

    /// 映像の接続を張り直すとき、前の接続の残りを捨ててキーフレームから描き直す。
    func reset() {
        displayLayer.sampleBufferRenderer.flush()
        formatDescription = nil
        waitingForKeyFrame = true
    }

    func handle(_ message: WireMessage) {
        switch message {
        case let .videoFormat(format):
            formatDescription = try? format.makeFormatDescription()
            onVideoSizeChange?(CGSize(width: format.width, height: format.height))
        case let .videoFrame(frame):
            enqueue(frame)
        case .control, .audio:
            break
        }
    }

    private func enqueue(_ frame: VideoFrame) {
        let renderer = displayLayer.sampleBufferRenderer
        // バックグラウンドに回ると表示レイヤが壊れる。戻ったら捨てて、キーフレームから描き直す
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
        renderer.enqueue(sampleBuffer)
    }

    private func restartFromKeyFrame() {
        guard !waitingForKeyFrame else { return }
        waitingForKeyFrame = true
        onNeedsKeyFrame?()
    }
}
