import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization
import VideoToolbox

/// キャプチャしたフレームを HEVC (作れなければ H.264) にエンコードして送る。回線に合わせたフレーム破棄とビットレート調整、拡大中の切り出し、画面が止まったあとの再送を受け持つ。
/// `send` は `queue` の上で呼ぶ。再送も同じキューで行う (エンコーダは同じスレッドから順に使う)。
public final class VideoSender: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public private(set) var codec = VideoCodec.hevc

    private let queue: DispatchQueue
    private let transmit: @Sendable (WireMessage) -> Void
    private let pendingSendCount: @Sendable () -> Int
    private let onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)?
    // VideoEncoder と CVPixelBuffer は Sendable でないため、Mutex ではなく NSLock で保護する
    private let lock = NSLock()
    private var encoder: VideoEncoder?
    private var isStopped = false
    private var region: VideoRegion
    // 画面が止まったあとに再送するため、最後にキャプチャしたフレームを 1 つだけ保持する
    private var lastSource: CVPixelBuffer?
    private var lastPresentationTime = CMTime.invalid
    private let refresh = Mutex(StillFrameRefresh())
    private let refreshTimer: any DispatchSourceTimer
    private let transferSession: VTPixelTransferSession?
    private let outputPool: CVPixelBufferPool?
    private let keyFrameRequested = Atomic(true)
    private let sentFrames = Atomic(0)
    private let flow: Mutex<VideoFlowControl>
    private let bitRateController: Mutex<BitRateController>
    private let roundTrip: Mutex<TimeInterval?>
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.kit", category: "video")

    /// `isAcknowledged`・`initialBitRate`・`initialRoundTrip` は、同じ映像の接続でキャプチャを作り直す前の値を引き継ぐ。
    /// `onQualityChange` は、回線に合わせてビットレートを変えるたびに、上限より大きく下げているかを渡す。`queue` から呼ばれる。
    public init(
        width: Int, height: Int, maximumBitRate: Int, frameRate: Int, region: VideoRegion = .full,
        isAcknowledged: Bool = false, initialBitRate: Int? = nil, initialRoundTrip: TimeInterval? = nil,
        queue: DispatchQueue, transmit: @escaping @Sendable (WireMessage) -> Void, pendingSendCount: @escaping @Sendable () -> Int = { 0 },
        onQualityChange: (@Sendable (_ isReduced: Bool) -> Void)? = nil
    ) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.region = region
        self.queue = queue
        self.transmit = transmit
        self.pendingSendCount = pendingSendCount
        self.onQualityChange = onQualityChange
        flow = Mutex(VideoFlowControl(isAcknowledged: isAcknowledged))
        let controller = BitRateController(maximum: maximumBitRate, initial: initialBitRate)
        bitRateController = Mutex(controller)
        roundTrip = Mutex(initialRoundTrip)
        // resume 前のタイマーを解放すると libdispatch がクラッシュするので、先に resume しておく
        refreshTimer = DispatchSource.makeTimerSource(queue: queue)
        refreshTimer.schedule(deadline: .distantFuture)
        refreshTimer.activate()

        var transferSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        if let transferSession {
            // 切り出しは、元のフレームに clean aperture を付け、その範囲だけを使わせて行う (切り出し範囲を直接指定する項目はない)
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
        // 作り直す前のビットレートから始める (上限から始めると、遅い回線では次の見直しまでの 2 秒間、輻輳が続く)
        do {
            encoder = try VideoEncoder(codec: .hevc, width: width, height: height, averageBitRate: controller.current, frameRate: frameRate, output: output)
        } catch {
            // HEVC は同じビットレートで文字がにじみにくい (流れる文字の輝度の PSNR で H.264 の 27dB に対し 40dB)。エンコーダを作れない Mac では H.264 にする
            Self.logger.notice("HEVC エンコーダを作成できないため H.264 を使用する: \(error, privacy: .public)")
            encoder = try VideoEncoder(codec: .h264, width: width, height: height, averageBitRate: controller.current, frameRate: frameRate, output: output)
            codec = .h264
        }
        refreshTimer.setEventHandler { [weak self] in
            self?.refreshIfStill()
        }
    }

    deinit {
        refreshTimer.cancel()
    }

    /// iPad が受信確認 (ACK) を返すと判明したか。
    public var isAcknowledged: Bool {
        flow.withLock { $0.isAcknowledged }
    }

    /// 回線に合わせて決めた今のビットレート。
    public var currentBitRate: Int {
        bitRateController.withLock { $0.current }
    }

    /// 平滑化した往復遅延 (RTT)。同じ映像の接続でキャプチャを作り直すときに引き継ぐ。
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
        let encoder = lock.withLock {
            isStopped = true
            lastSource = nil
            defer { self.encoder = nil }
            return self.encoder
        }
        refreshTimer.cancel()
        // VideoToolbox は内部のロックを持ったまま出力を渡し、エンコーダの破棄はその出力の完了を待つ。このロックを持ったまま破棄すると、出力がこのロックを待って互いに止まる
        _ = consume encoder
    }

    /// 次のフレームをキーフレームにする。画面が止まっていても、最後にキャプチャした画像で送る。
    public func requestKeyFrame() {
        keyFrameRequested.store(true, ordering: .relaxed)
        // タイマーの予定は、再送と同じキューで設定し直す (ほかのスレッドから設定すると、古い予定が後から上書きして再送が止まりうる)
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            refreshTimer.schedule(deadline: deadline(for: refresh.withLock { $0.requested(at: now); return $0.deadline }))
        }
    }

    /// iPad が見ている範囲を変える。範囲を切り出してから送るサイズに縮小する。
    public func setRegion(_ newRegion: VideoRegion) {
        let isChanged = lock.withLock {
            guard region != newRegion else { return false }
            region = newRegion
            return true
        }
        // 範囲が変わったら、差分ではなくキーフレームから描画させる
        if isChanged {
            requestKeyFrame()
        }
    }

    /// iPad がこのフレームを受信した。
    public func frameReceived(presentationTimeMicros: Int64) {
        let delivery = flow.withLock { $0.received(presentationTimeMicros: presentationTimeMicros, at: ProcessInfo.processInfo.systemUptime) }
        bitRateController.withLock { $0.delivered(delivery) }
        if let sample = delivery.roundTrip {
            roundTrip.withLock { $0 = VideoStats.smoothed($0, with: sample) }
        }
    }

    /// キャプチャしたフレームを送る。`queue` の上で呼ぶ。
    public func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let isRunning = lock.withLock {
            guard !isStopped else { return false }
            lastSource = pixelBuffer
            return true
        }
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 回線に入りきらない間はエンコード前に破棄し、遅延が積み上がらないようにする
        let (canSend, isWaitingForKeyFrame) = canSend(at: now)
        let change = isWaitingForKeyFrame ? nil : bitRateController.withLock { controller -> (rate: Int, isReduced: Bool)? in
            guard let rate = controller.record(isDropped: !canSend, at: now) else { return nil }
            return (rate, controller.isReduced)
        }
        if let change {
            lock.withLock { encoder }?.setAverageBitRate(change.rate)
            Self.logger.notice("映像のビットレートを回線状況に合わせて \(String(format: "%.1f", Double(change.rate) / 1_000_000), privacy: .public) Mbps に調整した")
            onQualityChange?(change.isReduced)
        }
        let isSent = canSend && encode(pixelBuffer, presentationTime: presentationTime)
        refreshTimer.schedule(deadline: deadline(for: refresh.withLock { $0.captured(isSent: isSent, at: now); return $0.deadline }))
    }

    private func canSend(at time: TimeInterval) -> (canSend: Bool, isWaitingForKeyFrame: Bool) {
        let (isAllowed, isWaitingForKeyFrame) = flow.withLock { ($0.canSend(at: time), $0.isWaitingForKeyFrame) }
        return (pendingSendCount() < 4 && isAllowed, isWaitingForKeyFrame)
    }

    private func encode(_ source: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        guard let (encoder, region) = lock.withLock({ () -> (VideoEncoder, VideoRegion)? in
            guard !isStopped, let encoder else { return nil }
            return (encoder, region)
        }) else { return false }
        var pixelBuffer = source
        if !region.isFull || CVPixelBufferGetWidth(source) != width || CVPixelBufferGetHeight(source) != height {
            // 範囲を切り出し、送るサイズに縮小する。キャプチャ設定の変更中に届いた古いサイズのフレームも、そのサイズに合わせて切り出す
            guard let transferSession, let outputPool, let output = Self.crop(source, region: region, session: transferSession, pool: outputPool) else { return false }
            pixelBuffer = output
        }
        let forceKeyFrame = keyFrameRequested.exchange(false, ordering: .relaxed)
        // 再送はホストの現在時刻で送るので、そのあとに届いたキャプチャ時刻 (ディスプレイに表示された時刻) はそれより前のことがある。受信確認は時刻の順に突き合わせるので、時刻は戻さない
        let time = Self.later(presentationTime, than: lock.withLock { lastPresentationTime })
        encoder.encode(pixelBuffer, presentationTime: time, forceKeyFrame: forceKeyFrame, region: region)
        lock.withLock { lastPresentationTime = time }
        return true
    }

    private func refreshIfStill() {
        guard let source = lock.withLock({ isStopped ? nil : lastSource }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let presentationTime = refreshPresentationTime()
        let (canSend, _) = canSend(at: now)
        let shouldRefresh = refresh.withLock { $0.fire(at: now, canSend: canSend, presentationTimeMicros: VideoFrame.presentationTimeMicros(of: presentationTime)) }
        if shouldRefresh {
            _ = encode(source, presentationTime: presentationTime)
        }
        refreshTimer.schedule(deadline: deadline(for: refresh.withLock { $0.deadline }))
    }

    /// 再送するフレームの時刻。キャプチャしたフレームと同じホストの時計で、前にエンコードしたフレームより後にする (受信確認は時刻で突き合わせる)。
    /// 実際に経過した時間を空けると、低遅延のレート制御が再送に予算を回す。1/60 秒ずつ詰めると、下げたビットレートでは画質が改善しなかった。
    private func refreshPresentationTime() -> CMTime {
        let now = CMTime(value: VideoFrame.presentationTimeMicros(of: CMClockGetTime(CMClockGetHostTimeClock())), timescale: 1_000_000)
        return Self.later(now, than: lock.withLock { lastPresentationTime })
    }

    /// `time` が `last` より 1ms 以上後でなければ、`last` の 1ms 後にする。
    private static func later(_ time: CMTime, than last: CMTime) -> CMTime {
        guard last.isNumeric else { return time }
        let earliest = CMTimeAdd(last, CMTime(value: 1, timescale: 1000))
        return CMTimeCompare(time, earliest) < 0 ? earliest : time
    }

    private func deadline(for time: TimeInterval?) -> DispatchTime {
        guard let time else { return .distantFuture }
        return .now() + max(0, time - ProcessInfo.processInfo.systemUptime)
    }

    private func encoded(_ format: VideoFormat?, _ frame: VideoFrame) {
        // 停止後にエンコーダから遅れて出力されたフレームを、同じ接続で作り直したキャプチャの映像に混ぜない
        guard !lock.withLock({ isStopped }) else { return }
        if let format {
            transmit(.videoFormat(format))
        }
        flow.withLock { $0.sent(presentationTimeMicros: frame.presentationTimeMicros, isKeyFrame: frame.isKeyFrame, bytes: frame.data.count, at: ProcessInfo.processInfo.systemUptime) }
        refresh.withLock { $0.encoded(presentationTimeMicros: frame.presentationTimeMicros, bytes: frame.data.count) }
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
        // 範囲は、ディスプレイ中心からのずれで指定する (右と下が正)。四隅を塗り分けたフレームで向きを確かめた
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
