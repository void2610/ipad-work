import CoreGraphics
import CoreMedia
import Foundation
import os
import PadBridgeKit
import ScreenCaptureKit
import Synchronization

enum ScreenStreamerError: Error {
    case displayNotFound
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
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "video")

    init(channel: MessageChannel, maxWidth: Int, maxHeight: Int) {
        self.channel = channel
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ScreenStreamerError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let size = Self.captureSize(
            pixelWidth: filter.contentRect.width * CGFloat(filter.pointPixelScale),
            pixelHeight: filter.contentRect.height * CGFloat(filter.pointPixelScale),
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
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

        let shouldStart = lock.withLock {
            guard !isStopped else { return false }
            self.stream = stream
            self.encoder = encoder
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

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // 送信が詰まっている間は符号化する前に捨て、遅延が積み上がらないようにする
        guard channel.pendingSendCount < 4, let encoder = lock.withLock({ self.encoder }) else { return }
        let forceKeyFrame = keyFrameRequested.exchange(false, ordering: .relaxed)
        encoder.encode(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp, forceKeyFrame: forceKeyFrame)
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
