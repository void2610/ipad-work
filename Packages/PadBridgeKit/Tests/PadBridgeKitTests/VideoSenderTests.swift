#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
@testable import PadBridgeKit
import Synchronization
import Testing
import VideoToolbox

/// 本物のエンコーダで、画面が静止したあとの再送を確認する。画面キャプチャの代わりに、文字のようなテストパターンを作って渡す。
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

    private let queue = DispatchQueue(label: "test.video-sender")

    /// 回線が輻輳して最後のフレームを破棄しても、画面が静止したら最後の映像を届ける (iPad に中途半端な映像が残らない)。
    @Test func deliversLastFrameDroppedByFullLink() async throws {
        let (width, height) = (640, 400)
        let recorder = Recorder()
        let sender = try makeSender(width: width, height: height, isAcknowledged: true, recorder: recorder)
        defer { sender.stop() }
        let images = try makeTexts(width: width, height: height, offsets: (0 ..< 4).map { $0 * 30 })
        for image in images {
            queue.sync { sender.send(image, presentationTime: Self.now()) }
        }
        // ACK 待ちは 3 フレームまでなので、4 フレーム目は破棄する
        try await waitUntil { recorder.frames.count >= 3 }
        #expect(recorder.frames.count == 3)
        for frame in recorder.frames {
            sender.frameReceived(presentationTimeMicros: frame.presentationTimeMicros)
        }
        try await waitUntil { recorder.frames.count >= 4 }
        let decoded = try decodeAll(recorder.all)
        let last = try #require(decoded.last)
        let toFourth = psnr(images[3], last)
        let toThird = psnr(images[2], last)
        #expect(toFourth > 30 && toFourth > toThird + 10, "4 フレーム目と \(toFourth)dB、3 フレーム目と \(toThird)dB")
    }

    /// 画面が静止している間に iPad がキーフレームを要求しても、次に画面が変わるのを待たずに届ける。
    @Test func answersKeyFrameRequestWhileStill() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let image = try makeText(width: 640, height: 400, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntilSettled(recorder)
        let before = recorder.frames.count

        sender.requestKeyFrame()
        try await waitUntil { recorder.frames.count > before }
        #expect(recorder.frames.last?.isKeyFrame == true)
    }

    /// 画面が静止している間に拡大範囲が変わっても、その範囲を切り出した映像を届ける。
    @Test func sendsNewRegionWhileStill() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let image = try makeText(width: 1280, height: 800, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntilSettled(recorder)
        #expect(recorder.frames.allSatisfy { $0.region == .full })

        let region = VideoRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        sender.setRegion(region)
        try await waitUntil { recorder.frames.last?.region == region }
        #expect(recorder.frames.last?.isKeyFrame == true)
    }

    /// 拡大している範囲を、切り出して送るサイズに縮め、範囲を付けたキーフレームから送る。
    @Test func sendsRegionFromKeyFrame() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let image = try makeText(width: 1280, height: 800, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntil { recorder.frames.count >= 1 }
        #expect(recorder.frames.first?.region == .full)

        let region = VideoRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        sender.setRegion(region)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntil { recorder.frames.count >= 2 }
        #expect(recorder.frames[1].region == region)
        #expect(recorder.frames[1].isKeyFrame)
    }

    /// 画面全体が切り替わってすぐ静止すると (アプリの切り替えやページの読み込み)、1 フレーム分の予算で描画した粗い画質のままになる。再送して鮮明にする。
    /// 測定結果は、上限のビットレートで 47.1dB から 53.1dB、上限の 0.4 倍で 29.2dB から 45.5dB に向上した。
    @Test(arguments: [(10, 3.0), (4, 10.0)])
    func sharpensStillFrameAfterSceneChange(tenthsOfMaximum: Int, expectedGain: Double) async throws {
        let (width, height) = (1920, 1080)
        let recorder = Recorder()
        let maximum = CaptureSize.bitRate(width: width, height: height)
        let sender = try makeSender(width: width, height: height, initialBitRate: maximum * tenthsOfMaximum / 10, recorder: recorder)
        defer { sender.stop() }
        // 前の映像を送り終え、レート制御が最初のキーフレームで超過した予算を返し終えてから切り替える (その間は画質を絞るので、比較できない)
        let images = try makeTexts(width: width, height: height, offsets: [0, 600])
        queue.sync { sender.send(images[0], presentationTime: Self.now()) }
        try await waitUntilSettled(recorder)
        try await Task.sleep(for: .milliseconds(300))
        let changedAt = Self.now()
        queue.sync { sender.send(images[1], presentationTime: changedAt) }
        try await waitUntilSettled(recorder)

        let frames = recorder.frames
        let decoded = try decodeAll(recorder.all)
        let changedIndex = try #require(frames.firstIndex { $0.presentationTimeMicros == VideoFrame.presentationTimeMicros(of: changedAt) })
        let atStop = psnr(images[1], decoded[changedIndex])
        let refreshed = psnr(images[1], try #require(decoded.last))
        #expect(refreshed > atStop + expectedGain, "切り替え時点 \(atStop)dB、再送後 \(refreshed)dB")
    }

    /// 画質が仕上がったら再送をやめ、静止した画面ではそれ以上送らない (電池と通信量を使わない)。
    @Test func stopsRefreshingWhenSettled() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let image = try makeText(width: 640, height: 400, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntilSettled(recorder)
        let count = recorder.frames.count
        #expect(count >= 2 && count <= 1 + StillFrameRefresh.maxRefreshes)
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.frames.count == count)
    }

    /// 停止したあとは、再送の時刻が来ても送らない (再作成したキャプチャの映像に混ぜない)。
    @Test func stopEndsRefreshes() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        let image = try makeText(width: 640, height: 400, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntil { recorder.frames.count >= 1 }
        sender.stop()
        let count = recorder.frames.count
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.frames.count == count)
    }

    /// 再送のあとに、それより古い時刻のキャプチャが届いても、送るフレームの時刻は戻らない (ACK は時刻順に突き合わせる)。
    @Test func keepsPresentationTimeIncreasing() async throws {
        let recorder = Recorder()
        let sender = try makeSender(width: 640, height: 400, recorder: recorder)
        defer { sender.stop() }
        let images = try makeTexts(width: 640, height: 400, offsets: [0, 300])
        queue.sync { sender.send(images[0], presentationTime: Self.now()) }
        try await waitUntil { recorder.frames.count >= 2 }
        let refreshed = try #require(recorder.frames.last)
        // 画面に表示された時刻は、再送をエンコードしたあとに届いても、再送より少し前になることがある
        let older = CMTime(value: refreshed.presentationTimeMicros - 5000, timescale: 1_000_000)
        queue.sync { sender.send(images[1], presentationTime: older) }
        try await waitUntil { recorder.frames.contains { $0.presentationTimeMicros > refreshed.presentationTimeMicros } }
        let times = recorder.frames.map(\.presentationTimeMicros)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "\(times)")
    }

    /// 停止したあとも、ACK の有無・ビットレート・往復遅延を読める (Host は停止してから読み、再作成するキャプチャに引き継ぐ)。
    @Test func keepsStateForHandOverAfterStop() async throws {
        let recorder = Recorder()
        let maximum = CaptureSize.bitRate(width: 640, height: 400)
        let sender = try makeSender(width: 640, height: 400, initialBitRate: maximum / 2, recorder: recorder)
        let image = try makeText(width: 640, height: 400, offset: 0)
        queue.sync { sender.send(image, presentationTime: Self.now()) }
        try await waitUntil { recorder.frames.count >= 1 }
        sender.frameReceived(presentationTimeMicros: try #require(recorder.frames.first).presentationTimeMicros)
        sender.stop()
        #expect(sender.isAcknowledged)
        #expect(sender.currentBitRate == maximum / 2)
        #expect(sender.currentRoundTrip != nil)
    }

    /// 再作成したエンコーダは、引き継いだビットレートから始める (上限から始めると、遅い回線では次の見直しまでの 2 秒間が輻輳する)。
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
                queue.sync { sender.send(image, presentationTime: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 60))) }
            }
            try await waitUntilSettled(recorder)
            // 最初のキーフレームは除く
            let frames = recorder.frames.dropFirst()
            return frames.map(\.data.count).reduce(0, +) / max(frames.count, 1)
        }
        let atMaximum = try await averageBytes(initialBitRate: nil)
        let handedOver = try await averageBytes(initialBitRate: maximum / 5)
        // 修正前は、どちらも同じサイズ (12941 バイト) だった。修正後は 4688 バイト
        #expect(handedOver * 2 < atMaximum, "上限から \(atMaximum) バイト、引き継いだ 1/5 から \(handedOver) バイト")
    }

    private func makeSender(width: Int, height: Int, isAcknowledged: Bool = false, initialBitRate: Int? = nil, recorder: Recorder) throws -> VideoSender {
        try VideoSender(
            width: width, height: height, maximumBitRate: CaptureSize.bitRate(width: width, height: height), frameRate: 60,
            isAcknowledged: isAcknowledged, initialBitRate: initialBitRate, queue: queue, transmit: { recorder.append($0) }
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

    /// 再送が終わるまで (0.4 秒増えなくなるまで) 待つ。
    private func waitUntilSettled(_ recorder: Recorder) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var count = recorder.frames.count
        var stableSince = ContinuousClock.now
        while ContinuousClock.now - stableSince < .milliseconds(400) {
            try #require(ContinuousClock.now < deadline, "再送が終わらない")
            try await Task.sleep(for: .milliseconds(20))
            let current = recorder.frames.count
            if current != count {
                count = current
                stableSince = ContinuousClock.now
            }
        }
    }

    /// 8x8 の濃淡のブロックを `seed` ごとに入れ替えたテストパターン。毎フレーム全体が変わり、上限のビットレートでは収まるが 1/5 では収まらない量にする。
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

    /// 9x18 のマス目に文字のような線を並べたテストパターン。`offset` だけ下へずらす (スクロール)。
    private func makeText(width: Int, height: Int, offset: Int) throws -> CVPixelBuffer {
        try makeTexts(width: width, height: height, offsets: [offset])[0]
    }

    /// 縦に長いテストパターンを 1 度だけ描画し、`offsets` ごとにずらした行を切り出す (デバッグビルドでは、1 フレームずつ描画すると 1920x1080 で 1 フレーム 0.1 秒以上かかる)。
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

    /// 送られた順にデコードし、フレームごとの映像を返す。
    private func decodeAll(_ messages: [WireMessage]) throws -> [CVPixelBuffer] {
        var decoder: Decoder?
        var description: CMVideoFormatDescription?
        var decoded: [CVPixelBuffer] = []
        for message in messages {
            switch message {
            case let .videoFormat(format):
                let made = try format.makeFormatDescription()
                description = made
                decoder = try Decoder(formatDescription: made)
            case let .videoFrame(frame):
                let description = try #require(description)
                decoded.append(try #require(try decoder?.decode(frame.makeSampleBuffer(formatDescription: description))))
            default:
                break
            }
        }
        return decoded
    }

    /// 輝度の PSNR (dB)。
    private func psnr(_ original: CVPixelBuffer, _ decoded: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(original, .readOnly)
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(original, .readOnly)
            CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        }
        let width = CVPixelBufferGetWidth(original)
        let height = CVPixelBufferGetHeight(original)
        guard CVPixelBufferGetWidth(decoded) == width, CVPixelBufferGetHeight(decoded) == height,
              let a = CVPixelBufferGetBaseAddressOfPlane(original, 0)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)?.assumingMemoryBound(to: UInt8.self)
        else { return 0 }
        let (rowA, rowB) = (CVPixelBufferGetBytesPerRowOfPlane(original, 0), CVPixelBufferGetBytesPerRowOfPlane(decoded, 0))
        var sum = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                let difference = Int(a[y * rowA + x]) - Int(b[y * rowB + x])
                sum += difference * difference
            }
        }
        let mse = max(Double(sum) / Double(width * height), 1e-9)
        return 10 * log10(255 * 255 / mse)
    }

    private final class Decoder {
        private let session: VTDecompressionSession

        init(formatDescription: CMVideoFormatDescription) throws {
            var session: VTDecompressionSession?
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: nil,
                imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session
            )
            self.session = try #require(session, "VTDecompressionSessionCreate: \(status)")
        }

        func decode(_ sampleBuffer: CMSampleBuffer) throws -> CVPixelBuffer? {
            final class Box: @unchecked Sendable {
                var image: CVPixelBuffer?
            }
            let box = Box()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                if status == noErr {
                    box.image = imageBuffer
                }
            }
            #expect(status == noErr)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            return box.image
        }
    }
}
#endif
