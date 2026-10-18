#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
@testable import PadBridgeKit
import Synchronization
import Testing
import VideoToolbox

/// 本物のエンコーダで、取り込んだフレームを送る流れを確かめる。画面の取り込みの代わりに、文字のような模様を作って渡す。
@Suite(.serialized)
struct VideoSenderTests {
    private final class Recorder: Sendable {
        private let messages = Mutex<[WireMessage]>([])

        func append(_ message: WireMessage) {
            messages.withLock { $0.append(message) }
        }

        var frames: [VideoFrame] {
            messages.withLock { $0.compactMap { if case let .videoFrame(frame) = $0 { frame } else { nil } } }
        }

        var all: [WireMessage] {
            messages.withLock { $0 }
        }
    }

    /// 止めたあとも、返事の有無・ビットレート・往復の遅れを読める (Host は止めてから読み、作り直す取り込みに引き継ぐ)。
    @Test func keepsStateForHandOverAfterStop() async throws {
        let recorder = Recorder()
        let maximum = CaptureSize.bitRate(width: 640, height: 400)
        let sender = try makeSender(width: 640, height: 400, initialBitRate: maximum / 2, recorder: recorder)
        let image = try makeText(width: 640, height: 400, offset: 0)
        sender.send(image, presentationTime: Self.now())
        try await waitUntil { recorder.frames.count >= 1 }
        sender.frameReceived(presentationTimeMicros: try #require(recorder.frames.first).presentationTimeMicros)
        sender.stop()
        #expect(sender.isAcknowledged)
        #expect(sender.currentBitRate == maximum / 2)
        #expect(sender.currentRoundTrip != nil)
    }

    /// 拡大している範囲を、切り出して送る大きさに縮め、範囲を付けたキーフレームから送る。
    @Test func sendsRegionFromKeyFrame() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let image = try makeText(width: 1280, height: 800, offset: 0)
        sender.send(image, presentationTime: Self.now())
        try await waitUntil { recorder.frames.count >= 1 }
        #expect(recorder.frames.first?.region == .full)

        let region = VideoRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        sender.setRegion(region)
        sender.send(image, presentationTime: Self.now())
        try await waitUntil { recorder.frames.count >= 2 }
        #expect(recorder.frames.last?.region == region)
        #expect(recorder.frames.last?.isKeyFrame == true)
    }

    /// 作り直したエンコーダは、引き継いだビットレートから始める (上限から始めると、遅い回線では次に見直すまでの 2 秒を詰まらせる)。
    @Test func startsAtHandedOverBitRate() async throws {
        let (width, height) = (640, 360)
        let maximum = CaptureSize.bitRate(width: width, height: height)
        let images = try (0 ..< 40).map { try makeBlocks(width: width, height: height, seed: $0) }
        func averageBytes(initialBitRate: Int?) async throws -> Int {
            let recorder = Recorder()
            let sender = try makeSender(width: width, height: height, initialBitRate: initialBitRate, recorder: recorder)
            defer { sender.stop() }
            let start = CMTimeSubtract(Self.now(), CMTime(value: 40, timescale: 60))
            for (index, image) in images.enumerated() {
                sender.send(image, presentationTime: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 60)))
            }
            try await waitUntilSettled(recorder)
            // 最初のキーフレームは除く
            let frames = recorder.frames.dropFirst()
            return frames.map(\.data.count).reduce(0, +) / max(frames.count, 1)
        }
        let atMaximum = try await averageBytes(initialBitRate: nil)
        let handedOver = try await averageBytes(initialBitRate: maximum / 5)
        // 直す前は、どちらも同じ大きさ (12941 バイト) だった。直したあとは 4688 バイト
        #expect(handedOver * 2 < atMaximum, "上限から \(atMaximum) バイト、引き継いだ 1/5 から \(handedOver) バイト")
    }

    private func makeSender(width: Int, height: Int, isAcknowledged: Bool = false, initialBitRate: Int? = nil, recorder: Recorder) throws -> VideoSender {
        try VideoSender(
            width: width, height: height, maximumBitRate: CaptureSize.bitRate(width: width, height: height), frameRate: 60,
            isAcknowledged: isAcknowledged, initialBitRate: initialBitRate, transmit: { recorder.append($0) }
        )
    }

    private static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "時間内に届かない")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 送り直しが終わるまで (0.4 秒増えなくなるまで) 待つ。
    private func waitUntilSettled(_ recorder: Recorder) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var count = recorder.frames.count
        var stableSince = ContinuousClock.now
        while ContinuousClock.now - stableSince < .milliseconds(400) {
            try #require(ContinuousClock.now < deadline, "送り直しが終わらない")
            try await Task.sleep(for: .milliseconds(20))
            let current = recorder.frames.count
            if current != count {
                count = current
                stableSince = ContinuousClock.now
            }
        }
    }

    /// 8x8 の濃淡のブロックを `seed` ごとに替えた模様。毎フレーム全体が変わり、上限のビットレートでは収まるが 1/5 では収まらない量にする。
    private func makeBlocks(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
        let buffer = try #require(pixelBuffer, "CVPixelBufferCreate: \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var hash = UInt32(x / 8) &* 73_856_093 ^ UInt32(y / 8) &* 19_349_663 ^ UInt32(seed) &* 83_492_791
                hash ^= hash >> 13
                hash = hash &* 1_274_126_177
                luma[y * bytesPerRow + x] = UInt8(truncatingIfNeeded: hash >> 24)
            }
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    /// 9x18 の升に文字のような線を並べた模様。`offset` だけ下へずらす (スクロール)。
    private func makeText(width: Int, height: Int, offset: Int) throws -> CVPixelBuffer {
        try makeTexts(width: width, height: height, offsets: [offset])[0]
    }

    /// 縦に長い模様を 1 度だけ描き、`offsets` ごとにずらした行を写す (デバッグの組み立てでは、1 枚ずつ描くと 1920x1080 で 1 枚 0.1 秒以上かかる)。
    private func makeTexts(width: Int, height: Int, offsets: [Int]) throws -> [CVPixelBuffer] {
        let rows = height + (offsets.max() ?? 0)
        var pattern = [UInt8](repeating: 235, count: width * rows)
        for row in 0 ..< rows {
            let (cellY, inY) = (row / 18, row % 18)
            guard inY < 14 else { continue }
            for x in 0 ..< width {
                let (cellX, inX) = (x / 9, x % 9)
                guard inX < 7, cellX % 40 <= 30 else { continue }
                var hash = UInt32(truncatingIfNeeded: cellX) &* 73_856_093 ^ UInt32(truncatingIfNeeded: cellY) &* 19_349_663
                hash ^= UInt32(inX / 2) &* 83_492_791 ^ UInt32(inY / 3) &* 2_654_435_761
                hash ^= hash >> 13
                hash = hash &* 1_274_126_177
                hash ^= hash >> 16
                pattern[row * width + x] = hash & 3 == 0 ? 16 : 235
            }
        }
        return try offsets.map { offset in
            var pixelBuffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
            let buffer = try #require(pixelBuffer, "CVPixelBufferCreate: \(status)")
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            pattern.withUnsafeBytes { source in
                for y in 0 ..< height {
                    memcpy(luma + y * bytesPerRow, source.baseAddress! + (y + offset) * width, width)
                }
            }
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            return buffer
        }
    }
}
#endif
