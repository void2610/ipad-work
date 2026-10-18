@testable import PadBridgeKit
import Testing

struct StillFrameRefreshTests {
    /// 映像が動いている間 (キャプチャのたびに) は再送せず、静止してから少し待って再送する。
    @Test func waitsUntilScreenStops() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        #expect(refresh.deadline == StillFrameRefresh.delay)
        let fired1 = refresh.fire(at: 0.1, canSend: true, presentationTimeMicros: 1)
        #expect(!fired1)
        refresh.captured(isSent: true, at: 0.1)
        #expect(refresh.deadline == 0.1 + StillFrameRefresh.delay)
        let fired2 = refresh.fire(at: 0.1 + StillFrameRefresh.delay, canSend: true, presentationTimeMicros: 2)
        #expect(fired2)
    }

    /// 画質が仕上がらなくても、規定回数でやめる (静止した映像で送り続けない)。
    @Test func stopsAfterLimit() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        var count = 0
        var micros: Int64 = 0
        while let deadline = refresh.deadline, count < 100 {
            micros += 1
            if refresh.fire(at: deadline, canSend: true, presentationTimeMicros: micros) {
                count += 1
                refresh.encoded(presentationTimeMicros: micros, bytes: 50000)
            }
        }
        #expect(count == StillFrameRefresh.maxRefreshes)
        #expect(refresh.deadline == nil)
    }

    /// レート制御に破棄されて出力されなかった再送は数えず、要求する回数の上限までは続ける。
    @Test func countsOnlyRefreshesThatCameOut() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        var attempts = 0
        var micros: Int64 = 0
        while let deadline = refresh.deadline, attempts < 100 {
            micros += 1
            if refresh.fire(at: deadline, canSend: true, presentationTimeMicros: micros) {
                attempts += 1
                // 1 回おきに出力される
                if attempts.isMultiple(of: 2) {
                    refresh.encoded(presentationTimeMicros: micros, bytes: 50000)
                }
            }
        }
        #expect(attempts == StillFrameRefresh.maxAttempts)

        refresh.captured(isSent: true, at: 100)
        var withoutOutput = 0
        while let deadline = refresh.deadline, withoutOutput < 100 {
            micros += 1
            if refresh.fire(at: deadline, canSend: true, presentationTimeMicros: micros) {
                withoutOutput += 1
            }
        }
        #expect(withoutOutput == StillFrameRefresh.maxAttempts)
    }

    /// 再送したフレームが小さければ、すでに画質が仕上がっているのでやめる (上限のビットレートでは 1 回目で止まる)。
    @Test func stopsWhenRefreshIsSmall() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        let fired3 = refresh.fire(at: 0.25, canSend: true, presentationTimeMicros: 7)
        #expect(fired3)
        // 再送ではないフレームのサイズでは判断しない
        refresh.encoded(presentationTimeMicros: 6, bytes: 10)
        let fired4 = refresh.fire(at: 0.35, canSend: true, presentationTimeMicros: 8)
        #expect(fired4)
        refresh.encoded(presentationTimeMicros: 8, bytes: StillFrameRefresh.settledBytes - 1)
        let deadline = refresh.deadline ?? 0
        let fired5 = refresh.fire(at: deadline, canSend: true, presentationTimeMicros: 9)
        #expect(!fired5)
        #expect(refresh.deadline == nil)
    }

    /// 回線が輻輳している間は回数を消費せずに待ち、空いたら送る (破棄した最後のフレームを必ず届ける)。
    @Test func waitsWhileLinkIsFull() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: false, at: 0)
        var time = StillFrameRefresh.delay
        for _ in 0 ..< 30 {
            let fired6 = refresh.fire(at: time, canSend: false, presentationTimeMicros: 1)
            #expect(!fired6)
            time += StillFrameRefresh.interval
            #expect(refresh.deadline == time)
        }
        let fired7 = refresh.fire(at: time, canSend: true, presentationTimeMicros: 2)
        #expect(fired7)
    }

    /// 画質が仕上がって停止したあとでも、キーフレームや範囲を要求されたら 1 回送る。
    @Test func requestRefreshesSettledFrame() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        let fired8 = refresh.fire(at: 0.25, canSend: true, presentationTimeMicros: 1)
        #expect(fired8)
        refresh.encoded(presentationTimeMicros: 1, bytes: 100)
        let fired9 = refresh.fire(at: 0.35, canSend: true, presentationTimeMicros: 2)
        #expect(!fired9)
        #expect(refresh.deadline == nil)

        refresh.requested(at: 5)
        #expect(refresh.deadline == 5 + StillFrameRefresh.interval)
        let fired10 = refresh.fire(at: 5 + StillFrameRefresh.interval, canSend: true, presentationTimeMicros: 3)
        #expect(fired10)
        refresh.encoded(presentationTimeMicros: 3, bytes: 30000)
        // キーフレームは大きいが、画質はすでに仕上がっているので続けない
        let deadline = refresh.deadline ?? 0
        let fired11 = refresh.fire(at: deadline, canSend: true, presentationTimeMicros: 4)
        #expect(!fired11)
    }

    /// 要求されたときにすでに再送待ちであれば、早い方で送る。
    @Test func requestDoesNotDelayPendingRefresh() {
        var refresh = StillFrameRefresh()
        refresh.captured(isSent: true, at: 0)
        refresh.requested(at: 0.2)
        #expect(refresh.deadline == StillFrameRefresh.delay)
        refresh.requested(at: 0)
        #expect(refresh.deadline == StillFrameRefresh.interval)
    }
}
