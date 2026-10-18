import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization
import VideoToolbox

/// 取り込んだ画面のフレームを HEVC (作れなければ H.264) にして送る。回線に合わせた間引きとビットレートと、拡大している間の切り出しを受け持つ。
/// `send` は同じスレッドから順に呼ぶ (エンコーダは同じスレッドから順に使う)。
public final class VideoSender: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public private(set) var codec = VideoCodec.hevc

    private let transmit: @Sendable (WireMessage) -> Void
    private let pendingSendCount: @Sendable () -> Int
    private let onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)?
    // VideoEncoder は Sendable でないため、Mutex ではなく NSLock で守る
    private let lock = NSLock()
    private var encoder: VideoEncoder?
    private var isStopped = false
    private var region: VideoRegion
    private let transferSession: VTPixelTransferSession?
    private let outputPool: CVPixelBufferPool?
    private let keyFrameRequested = Atomic(true)
    private let sentFrames = Atomic(0)
    private let flow: Mutex<VideoFlowControl>
    private let bitRateController: Mutex<BitRateController>
    private let roundTrip: Mutex<TimeInterval?>
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.kit", category: "video")

    /// `isAcknowledged`・`initialBitRate`・`initialRoundTrip` は、同じ映像の接続で作り直す前の取り込みから引き継ぐ。
    /// `onQualityChange` は、回線に合わせてビットレートを変えるたびに、上限より大きく下げているかを渡す。`send` を呼んだスレッドから呼ばれる。
    public init(
        width: Int, height: Int, maximumBitRate: Int, frameRate: Int, region: VideoRegion = .full,
        isAcknowledged: Bool = false, initialBitRate: Int? = nil, initialRoundTrip: TimeInterval? = nil,
        transmit: @escaping @Sendable (WireMessage) -> Void, pendingSendCount: @escaping @Sendable () -> Int = { 0 },
        onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)? = nil
    ) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.region = region
        self.transmit = transmit
        self.pendingSendCount = pendingSendCount
        self.onQualityChange = onQualityChange
        flow = Mutex(VideoFlowControl(isAcknowledged: isAcknowledged))
        let controller = BitRateController(maximum: maximumBitRate, initial: initialBitRate)
        bitRateController = Mutex(controller)
        roundTrip = Mutex(initialRoundTrip)

        var transferSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        if let transferSession {
            // 切り出しは、元のフレームに付けた clean aperture の範囲だけを使わせて行う (切り出す範囲を直接指定する項目はない)
            VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
        }
        self.transferSession = transferSession
        var pool: CVPixelBufferPool?
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pool)
        outputPool = pool

        let output: VideoEncoder.OutputHandler = { [weak self] format, frame in
            self?.encoded(format, frame)
        }
        do {
            encoder = try VideoEncoder(codec: .hevc, width: width, height: height, averageBitRate: maximumBitRate, frameRate: frameRate, output: output)
        } catch {
            // HEVC は同じビットレートで文字がにじみにくい (流れる文字の輝度の PSNR で H.264 の 27dB に対し 40dB)。作れない Mac では H.264 にする
            Self.logger.notice("HEVC のエンコーダを作れないので H.264 にする: \(error, privacy: .public)")
            encoder = try VideoEncoder(codec: .h264, width: width, height: height, averageBitRate: maximumBitRate, frameRate: frameRate, output: output)
            codec = .h264
        }
    }

    /// iPad が受け取りの返事を返すと分かったか。
    public var isAcknowledged: Bool {
        flow.withLock { $0.isAcknowledged }
    }

    /// 回線に合わせて決めた今のビットレート。
    public var currentBitRate: Int {
        bitRateController.withLock { $0.current }
    }

    /// ならした往復の遅れ。同じ映像の接続で作り直すときに引き継ぐ。
    public var currentRoundTrip: TimeInterval? {
        roundTrip.withLock { $0 }
    }

    /// iPad の「接続の状態」に出す、今の映像の状態。
    public var stats: VideoStats {
        let rates = bitRateController.withLock { (current: $0.current, maximum: $0.maximum) }
        let roundTrip = roundTrip.withLock { $0 }
        return VideoStats(
            codec: codec, width: width, height: height, bitRate: rates.current, maximumBitRate: rates.maximum,
            roundTripMillis: roundTrip.map { Int(($0 * 1000).rounded()) }, frameRate: frameRate
        )
    }

    public func stop() {
        lock.withLock {
            isStopped = true
            encoder = nil
        }
    }

    /// 次のフレームをキーフレームにする。
    public func requestKeyFrame() {
        keyFrameRequested.store(true, ordering: .relaxed)
    }

    /// iPad が見ている範囲を変える。範囲を切り出してから送る大きさに縮める。
    public func setRegion(_ newRegion: VideoRegion) {
        let isChanged = lock.withLock {
            guard region != newRegion else { return false }
            region = newRegion
            return true
        }
        // 範囲が変わったら、差分ではなくキーフレームから描かせる
        if isChanged {
            requestKeyFrame()
        }
    }

    /// iPad がこのフレームを受け取った。
    public func frameReceived(presentationTimeMicros: Int64) {
        let delivery = flow.withLock { $0.received(presentationTimeMicros: presentationTimeMicros, at: ProcessInfo.processInfo.systemUptime) }
        bitRateController.withLock { $0.delivered(delivery) }
        if let sample = delivery.roundTrip {
            roundTrip.withLock { $0 = VideoStats.smoothed($0, with: sample) }
        }
    }

    /// 取り込んだフレームを送る。
    public func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard !lock.withLock({ isStopped }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 回線に入りきらない間は符号化する前に捨て、遅延が積み上がらないようにする
        let (canSend, isWaitingForKeyFrame) = canSend(at: now)
        let change = isWaitingForKeyFrame ? nil : bitRateController.withLock { controller -> (rate: Int, isReduced: Bool)? in
            guard let rate = controller.record(isDropped: !canSend, at: now) else { return nil }
            return (rate, controller.isReduced)
        }
        if let change {
            lock.withLock { encoder }?.setAverageBitRate(change.rate)
            Self.logger.notice("回線に合わせて映像のビットレートを \(String(format: "%.1f", Double(change.rate) / 1_000_000), privacy: .public) Mbps にした")
            onQualityChange?(change.isReduced)
        }
        if canSend {
            encode(pixelBuffer, presentationTime: presentationTime)
        }
    }

    private func canSend(at time: TimeInterval) -> (canSend: Bool, isWaitingForKeyFrame: Bool) {
        let (isAllowed, isWaitingForKeyFrame) = flow.withLock { ($0.canSend(at: time), $0.isWaitingForKeyFrame) }
        return (pendingSendCount() < 4 && isAllowed, isWaitingForKeyFrame)
    }

    private func encode(_ source: CVPixelBuffer, presentationTime: CMTime) {
        guard let (encoder, region) = lock.withLock({ () -> (VideoEncoder, VideoRegion)? in
            guard !isStopped, let encoder else { return nil }
            return (encoder, region)
        }) else { return }
        var pixelBuffer = source
        if !region.isFull || CVPixelBufferGetWidth(source) != width || CVPixelBufferGetHeight(source) != height {
            // 範囲を切り出し、送る大きさに縮める。取り込みの設定を変えている途中の古い大きさのフレームも、その大きさに合わせて切り出す
            guard let transferSession, let outputPool, let output = Self.crop(source, region: region, session: transferSession, pool: outputPool) else { return }
            pixelBuffer = output
        }
        let forceKeyFrame = keyFrameRequested.exchange(false, ordering: .relaxed)
        encoder.encode(pixelBuffer, presentationTime: presentationTime, forceKeyFrame: forceKeyFrame, region: region)
    }

    private func encoded(_ format: VideoFormat?, _ frame: VideoFrame) {
        // 止めたあとにエンコーダから遅れて出たフレームを、同じ接続で作り直した取り込みの映像に混ぜない
        guard !lock.withLock({ isStopped }) else { return }
        if let format {
            transmit(.videoFormat(format))
        }
        flow.withLock { $0.sent(presentationTimeMicros: frame.presentationTimeMicros, isKeyFrame: frame.isKeyFrame, bytes: frame.data.count, at: ProcessInfo.processInfo.systemUptime) }
        transmit(.videoFrame(frame))
        let count = sentFrames.add(1, ordering: .relaxed).newValue
        if count == 1 || count.isMultiple(of: 600) {
            Self.logger.info("映像を送信: \(count) フレーム目 (\(frame.data.count) バイト)")
        }
    }

    private static func crop(_ source: CVPixelBuffer, region: VideoRegion, session: VTPixelTransferSession, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess, let output else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))
        let crop = region.rect(in: CGRect(x: 0, y: 0, width: width, height: height)).integral
        // 範囲は、画面の中心からのずれで指定する (右と下が正)。四隅を塗り分けたフレームで向きを確かめた
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: crop.width,
            kCVImageBufferCleanApertureHeightKey: crop.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: crop.midX - width / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: crop.midY - height / 2,
        ]
        CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        return VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr ? output : nil
    }
}
