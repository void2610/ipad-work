import CoreGraphics
import CoreMedia
import Foundation
import os
import PadBridgeKit
import ScreenCaptureKit

enum ScreenStreamerError: Error {
    case displayNotFound
}

/// 映している画面と、その大きさ。取り込みを作り直すべき変化かを見分ける。
nonisolated struct DisplayLayout: Equatable {
    var displayID: CGDirectDisplayID
    var bounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int

    init(of displayID: CGDirectDisplayID) {
        let mode = CGDisplayCopyDisplayMode(displayID)
        self.displayID = displayID
        bounds = CGDisplayBounds(displayID)
        pixelWidth = mode?.pixelWidth ?? 0
        pixelHeight = mode?.pixelHeight ?? 0
    }
}

/// 画面を 1 台取り込み、`VideoSender` で符号化して映像用の接続へ流す。
nonisolated final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let channel: MessageChannel
    private let displayID: CGDirectDisplayID
    private let maxWidth: Int
    private let maxHeight: Int
    private let sampleQueue = DispatchQueue(label: "dev.void2610.padbridge.host.capture")
    // SCStream は Sendable でないため、Mutex ではなく NSLock で守る
    private let lock = NSLock()
    private var stream: SCStream?
    private var sender: VideoSender?
    private var isStopped = false
    private let initialAcknowledged: Bool
    private let initialBitRate: Int?
    private let initialRoundTrip: TimeInterval?
    private let onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)?
    private let frameRate: Int
    // iPad が見ている範囲。拡大している間は画面を元の解像度で取り込み、この範囲だけを切り出して送る
    private var region = VideoRegion.full
    private var configuration: SCStreamConfiguration?
    private var outputSize = (width: 0, height: 0)
    private var nativeSize = (width: 0, height: 0)
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "video")

    /// `isAcknowledged` と `initialBitRate` は、同じ映像の接続で作り直す前の取り込みから引き継ぐ。
    /// `onQualityChange` は、回線に合わせてビットレートを変えるたびに、上限より大きく下げているかを渡す。取り込みのキューから呼ばれる。
    init(
        channel: MessageChannel, displayID: CGDirectDisplayID, maxWidth: Int, maxHeight: Int, region: VideoRegion,
        isAcknowledged: Bool = false, initialBitRate: Int? = nil, initialRoundTrip: TimeInterval? = nil, frameRate: Int = PreferredFrameRate.normal,
        onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)? = nil
    ) {
        self.channel = channel
        self.frameRate = frameRate
        initialAcknowledged = isAcknowledged
        self.initialBitRate = initialBitRate
        self.initialRoundTrip = initialRoundTrip
        self.onQualityChange = onQualityChange
        self.displayID = displayID
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.region = region
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // 別の画面で代わりに映すと、触った位置がその画面に届かないので、見つからなければ始めない
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenStreamerError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        let pixelHeight = filter.contentRect.height * CGFloat(filter.pointPixelScale)
        let size = CaptureSize.fitting(pixelWidth: pixelWidth, pixelHeight: pixelHeight, limitWidth: maxWidth, limitHeight: maxHeight)
        let native = (width: Int(pixelWidth) & ~1, height: Int(pixelHeight) & ~1)

        let configuration = SCStreamConfiguration()
        let initialRegion = lock.withLock { region }
        let captureSize = initialRegion.isFull ? size : native
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 4

        let bitRate = CaptureSize.bitRate(width: size.width, height: size.height)
        let sender = try VideoSender(
            width: size.width, height: size.height, maximumBitRate: bitRate, frameRate: frameRate, region: initialRegion,
            isAcknowledged: initialAcknowledged, initialBitRate: initialBitRate, initialRoundTrip: initialRoundTrip,
            queue: sampleQueue, transmit: { [channel] in channel.send($0) }, pendingSendCount: { [channel] in channel.pendingSendCount },
            onQualityChange: onQualityChange
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        let latestRegion: VideoRegion? = lock.withLock {
            guard !isStopped else { return nil }
            self.stream = stream
            self.sender = sender
            self.configuration = configuration
            self.outputSize = size
            self.nativeSize = native
            return region
        }
        guard let latestRegion else {
            sender.stop()
            return
        }
        // 取り込みを用意している間に範囲が変わっていたら、それに合わせる
        if latestRegion != initialRegion {
            sender.setRegion(latestRegion)
            if latestRegion.isFull != initialRegion.isFull {
                updateCaptureSize(stream: stream, configuration: configuration, isFull: latestRegion.isFull)
            }
        }
        try await stream.startCapture()
        // 始めている途中で止められたときは、止める処理がまだ始まっていない取り込みに効かず、取り込みが動き続ける。始め終えたところで止め直す
        if lock.withLock({ isStopped }) {
            try? await stream.stopCapture()
            return
        }
        Self.logger.info("画面の取り込みを開始: 画面 \(self.displayID)、\(size.width)x\(size.height)、\(sender.codec == .hevc ? "HEVC" : "H.264", privacy: .public)、\(bitRate / 1_000_000) Mbps")
    }

    func stop() {
        // 送る側は手放さない。作り直すときに、止めたこの取り込みから返事の有無とビットレートを読んで引き継ぐ
        let (stream, sender) = lock.withLock {
            isStopped = true
            defer { self.stream = nil }
            return (self.stream, self.sender)
        }
        sender?.stop()
        stream?.stopCapture { _ in }
    }

    func requestKeyFrame() {
        lock.withLock { sender }?.requestKeyFrame()
    }

    /// iPad が受け取りの返事を返すと分かったか。
    var isAcknowledged: Bool {
        lock.withLock { sender }?.isAcknowledged ?? initialAcknowledged
    }

    /// 回線に合わせて決めた今のビットレート。取り込みを始める前は nil。
    var currentBitRate: Int? {
        lock.withLock { sender }?.currentBitRate
    }

    /// ならした往復の遅れ。同じ映像の接続で作り直すときに引き継ぐ。
    var currentRoundTrip: TimeInterval? {
        guard let sender = lock.withLock({ sender }) else { return initialRoundTrip }
        return sender.currentRoundTrip
    }

    /// iPad の「接続の状態」に出す、今の映像の状態。取り込みを始める前は nil。
    var stats: VideoStats? {
        lock.withLock { sender }?.stats
    }

    /// iPad がこのフレームを受け取った。
    func frameReceived(presentationTimeMicros: Int64) {
        lock.withLock { sender }?.frameReceived(presentationTimeMicros: presentationTimeMicros)
    }

    /// iPad が見ている範囲を変える。拡大している間だけ、画面を元の解像度で取り込む (等倍のときは iPad の解像度で十分なので、取り込みを軽くする)。
    func setRegion(_ newRegion: VideoRegion) {
        let (sender, update): (VideoSender?, (SCStream, SCStreamConfiguration)?) = lock.withLock {
            guard region != newRegion else { return (nil, nil) }
            let wasFull = region.isFull
            region = newRegion
            guard wasFull != newRegion.isFull, let stream, let configuration else { return (self.sender, nil) }
            return (self.sender, (stream, configuration))
        }
        sender?.setRegion(newRegion)
        if let (stream, configuration) = update {
            updateCaptureSize(stream: stream, configuration: configuration, isFull: newRegion.isFull)
        }
    }

    private func updateCaptureSize(stream: SCStream, configuration: SCStreamConfiguration, isFull: Bool) {
        let size = lock.withLock { isFull ? outputSize : nativeSize }
        configuration.width = size.width
        configuration.height = size.height
        stream.updateConfiguration(configuration) { error in
            if let error {
                Self.logger.error("取り込みの設定を変えられない: \(error, privacy: .public)")
            }
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer,
              let sender = lock.withLock({ sender })
        else { return }
        sender.send(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp)
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        // 作り直したあとの古い取り込みの知らせで、新しい取り込みが使っている映像の接続を閉じない
        guard !lock.withLock({ isStopped }) else { return }
        channel.cancel()
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
