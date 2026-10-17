import CoreGraphics
import CoreMedia
import Foundation
import os
import PadBridgeKit
import ScreenCaptureKit
import Synchronization
import VideoToolbox

enum ScreenStreamerError: Error {
    case displayNotFound
}

/// メインディスプレイと、その大きさ。取り込みを作り直すべき変化かを見分ける。
nonisolated struct DisplayLayout: Equatable {
    var displayID: CGDirectDisplayID
    var bounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int

    static func main() -> DisplayLayout {
        let displayID = CGMainDisplayID()
        let mode = CGDisplayCopyDisplayMode(displayID)
        return DisplayLayout(displayID: displayID, bounds: CGDisplayBounds(displayID), pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0)
    }
}

/// メインディスプレイを取り込み、H.264 にして映像用の接続へ流す。
nonisolated final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let channel: MessageChannel
    private let maxWidth: Int
    private let maxHeight: Int
    private let sampleQueue = DispatchQueue(label: "dev.void2610.padbridge.host.capture")
    // SCStream と H264Encoder は Sendable でないため、Mutex ではなく NSLock で守る
    private let lock = NSLock()
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var isStopped = false
    private let keyFrameRequested = Atomic(true)
    private let sentFrames = Atomic(0)
    // iPad が見ている範囲。拡大している間は画面を元の解像度で取り込み、この範囲だけを切り出して送る
    private var region = VideoRegion.full
    private var configuration: SCStreamConfiguration?
    private var outputSize = (width: 0, height: 0)
    private var nativeSize = (width: 0, height: 0)
    private var transferSession: VTPixelTransferSession?
    private var outputPool: CVPixelBufferPool?
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "video")

    init(channel: MessageChannel, maxWidth: Int, maxHeight: Int, region: VideoRegion) {
        self.channel = channel
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.region = region
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ScreenStreamerError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        let pixelHeight = filter.contentRect.height * CGFloat(filter.pointPixelScale)
        let size = Self.captureSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, maxWidth: maxWidth, maxHeight: maxHeight)
        let native = (width: Int(pixelWidth) & ~1, height: Int(pixelHeight) & ~1)

        let configuration = SCStreamConfiguration()
        let initialRegion = lock.withLock { region }
        let captureSize = initialRegion.isFull ? size : native
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 4

        let bitRate = min(max(size.width * size.height * 4, 8_000_000), 40_000_000)
        let encoder = try H264Encoder(width: size.width, height: size.height, averageBitRate: bitRate, frameRate: 60) { [channel, weak self] format, frame in
            if let format {
                channel.send(.videoFormat(format))
            }
            channel.send(.videoFrame(frame))
            guard let count = self?.sentFrames.add(1, ordering: .relaxed).newValue else { return }
            if count == 1 || count.isMultiple(of: 600) {
                Self.logger.info("映像を送信: \(count) フレーム目 (\(frame.data.count) バイト)")
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        var transferSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        if let transferSession {
            // 切り出しは、元のフレームに付けた clean aperture の範囲だけを使わせて行う (切り出す範囲を直接指定する項目はない)
            VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
        }
        var pool: CVPixelBufferPool?
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pool)

        let shouldStart = lock.withLock {
            guard !isStopped else { return false }
            self.stream = stream
            self.encoder = encoder
            self.configuration = configuration
            self.outputSize = size
            self.nativeSize = native
            self.transferSession = transferSession
            self.outputPool = pool
            return true
        }
        guard shouldStart else { return }
        try await stream.startCapture()
        Self.logger.info("画面の取り込みを開始: \(size.width)x\(size.height)、\(bitRate / 1_000_000) Mbps")
    }

    func stop() {
        let stream = lock.withLock {
            isStopped = true
            encoder = nil
            defer { self.stream = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    func requestKeyFrame() {
        keyFrameRequested.store(true, ordering: .relaxed)
    }

    /// iPad が見ている範囲を変える。拡大している間だけ、画面を元の解像度で取り込む (等倍のときは iPad の解像度で十分なので、取り込みを軽くする)。
    func setRegion(_ newRegion: VideoRegion) {
        let update: (SCStream, SCStreamConfiguration)? = lock.withLock {
            guard region != newRegion else { return nil }
            let wasFull = region.isFull
            region = newRegion
            guard wasFull != newRegion.isFull, let stream, let configuration else { return nil }
            let size = newRegion.isFull ? outputSize : nativeSize
            configuration.width = size.width
            configuration.height = size.height
            return (stream, configuration)
        }
        // 範囲が変わったら、差分ではなくキーフレームから描かせる
        requestKeyFrame()
        guard let (stream, configuration) = update else { return }
        stream.updateConfiguration(configuration) { error in
            if let error {
                Self.logger.error("取り込みの設定を変えられない: \(error, privacy: .public)")
            }
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // 送信が詰まっている間は符号化する前に捨て、遅延が積み上がらないようにする
        guard channel.pendingSendCount < 4,
              let (encoder, region, outputSize, transferSession, pool) = lock.withLock({ () -> (H264Encoder, VideoRegion, (width: Int, height: Int), VTPixelTransferSession?, CVPixelBufferPool?)? in
                  guard let encoder else { return nil }
                  return (encoder, self.region, self.outputSize, self.transferSession, self.outputPool)
              })
        else { return }
        let forceKeyFrame = keyFrameRequested.exchange(false, ordering: .relaxed)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if region.isFull, width == outputSize.width, height == outputSize.height {
            encoder.encode(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp, forceKeyFrame: forceKeyFrame)
            return
        }
        // 範囲を切り出し、送る大きさに縮める。取り込みの設定を変えている途中の古い大きさのフレームも、その大きさに合わせて切り出す
        guard let transferSession, let pool, let output = Self.crop(pixelBuffer, region: region, session: transferSession, pool: pool) else { return }
        encoder.encode(output, presentationTime: sampleBuffer.presentationTimeStamp, forceKeyFrame: forceKeyFrame, region: region)
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

    func stream(_: SCStream, didStopWithError _: any Error) {
        channel.cancel()
    }

    static func captureSize(pixelWidth: CGFloat, pixelHeight: CGFloat, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let scale = min(1, CGFloat(maxWidth) / pixelWidth, CGFloat(maxHeight) / pixelHeight)
        // H.264 の 4:2:0 は縦横とも偶数でないと符号化できない
        let width = Int(pixelWidth * scale) & ~1
        let height = Int(pixelHeight * scale) & ~1
        return (max(width, 2), max(height, 2))
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
