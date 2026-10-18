import Foundation

/// ディスプレイの更新が止まったあと、最後にキャプチャした画像を再エンコードして送るかを決める。
/// ScreenCaptureKit は画面が変わらないとフレームを出さないので、次の場合は再送しないと、次に Mac の画面が変わるまで直らない。
/// 輻輳で最後のフレームを破棄したとき (iPad に途中の画像が残り、タッチ位置と見た目がずれる)、下げたビットレートでぼやけた画像、
/// ディスプレイの更新が止まっている間に要求されたキーフレームと拡大範囲。
public struct StillFrameRefresh: Sendable {
    /// 最後にキャプチャしてから、再送を始めるまで。画面が動いている間 (60fps なら 17ms ごとにキャプチャする) は再送しない。
    public static let delay: TimeInterval = 0.25
    public static let interval: TimeInterval = 0.1
    /// 1 枚の画像を再送する回数 (実際に出力されたフレーム数) の上限。画像が丸ごと切り替わってすぐ止まったとき、上限の 0.4 倍のビットレートでも 6 回で 29dB から 45dB まで上がった (1920x1080 の文字パターン)。
    public static let maxRefreshes = 8
    /// 再送を要求する回数の上限。大きなキーフレームのあとは、低遅延のレート制御が予算を返済するために再送を 1 回おきに破棄するので、要求回数では数えない。
    public static let maxAttempts = maxRefreshes * 2
    /// 再送したフレームがこれより小さければ、画像はもう仕上がっているとみなして打ち切る (上限のビットレートで少しずつ動いて止まったときは、1 回目から 300 バイトほど)。
    public static let settledBytes = 1000

    /// 次に `fire` を呼ぶ時刻。nil なら、次にキャプチャするか要求されるまで再送しない。
    public private(set) var deadline: TimeInterval?
    private var refreshes = 0
    private var attempts = 0
    private var isSettled = false
    private var isRequested = false
    private var pendingMicros: Int64?

    public init() {}

    /// ディスプレイのフレームをキャプチャした。`isSent` は、輻輳で破棄せずにエンコードしたか。
    public mutating func captured(isSent: Bool, at time: TimeInterval) {
        refreshes = 0
        attempts = 0
        isSettled = false
        pendingMicros = nil
        // エンコードしたフレームが、要求されたキーフレームと範囲で送られている
        if isSent {
            isRequested = false
        }
        deadline = time + Self.delay
    }

    /// キーフレームか拡大範囲を要求された。画面が止まっていても、すぐ再送する。
    public mutating func requested(at time: TimeInterval) {
        isRequested = true
        deadline = min(deadline ?? .infinity, time + Self.interval)
    }

    /// `deadline` になったら呼ぶ。今再送するなら true を返し、`presentationTimeMicros` を再送したフレームとして記憶する。
    public mutating func fire(at time: TimeInterval, canSend: Bool, presentationTimeMicros: Int64) -> Bool {
        guard let deadline, time >= deadline else { return false }
        guard canSend else {
            self.deadline = time + Self.interval
            return false
        }
        guard isRequested || !isSettled && refreshes < Self.maxRefreshes && attempts < Self.maxAttempts else {
            self.deadline = nil
            return false
        }
        attempts += 1
        isRequested = false
        pendingMicros = presentationTimeMicros
        self.deadline = time + Self.interval
        return true
    }

    /// エンコードしたフレームが出力されたら呼ぶ。
    public mutating func encoded(presentationTimeMicros: Int64, bytes: Int) {
        guard presentationTimeMicros == pendingMicros else { return }
        pendingMicros = nil
        refreshes += 1
        if bytes < Self.settledBytes {
            isSettled = true
        }
    }
}
