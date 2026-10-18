import Foundation

/// 画面が止まったあと、最後に取り込んだ絵をもう一度符号化して送るかを決める。
/// ScreenCaptureKit は画面が変わらないとフレームを出さないので、次のものは送り直さないと、次に Mac の画面が変わるまで直らない。
/// 回線が詰まって最後のフレームを捨てたとき (iPad に途中の絵が残り、触る位置と見た目がずれる)、下げたビットレートでにじんだ絵、
/// 画面が止まっている間に頼まれたキーフレームと拡大の範囲。
public struct StillFrameRefresh: Sendable {
    /// 最後に取り込んでから、送り直し始めるまで。画面が動いている間 (60fps なら 17ms ごとに取り込む) は送り直さない。
    public static let delay: TimeInterval = 0.25
    public static let interval: TimeInterval = 0.1
    /// 1 枚の絵を送り直す回数 (実際に出てきたフレームの数) の上限。絵が丸ごと替わってすぐ止まったとき、上限の 0.4 倍のビットレートでも 6 回で 29dB から 45dB まで上がった (1920x1080 の文字の模様)。
    public static let maxRefreshes = 8
    /// 送り直しを頼む回数の上限。大きなキーフレームのあとは、低遅延のレート制御が借りを返すために送り直しを 1 回おきに落とすので、頼んだ回数では数えない。
    public static let maxAttempts = maxRefreshes * 2
    /// 送り直したフレームがこれより小さければ、絵はもう仕上がっているとみなしてやめる (上限のビットレートで少しずつ動いて止まったときは、1 回目から 300 バイトほど)。
    public static let settledBytes = 1000

    /// 次に `fire` を呼ぶ時刻。nil なら、次に取り込むか頼まれるまで送り直さない。
    public private(set) var deadline: TimeInterval?
    private var refreshes = 0
    private var attempts = 0
    private var isSettled = false
    private var isRequested = false
    private var pendingMicros: Int64?

    public init() {}

    /// 画面のフレームを取り込んだ。`isSent` は、回線が詰まって捨てずに符号化したか。
    public mutating func captured(isSent: Bool, at time: TimeInterval) {
        refreshes = 0
        attempts = 0
        isSettled = false
        pendingMicros = nil
        // 符号化したフレームが、頼まれたキーフレームと範囲で送られている
        if isSent {
            isRequested = false
        }
        deadline = time + Self.delay
    }

    /// キーフレームか拡大の範囲を頼まれた。画面が止まっていても、すぐ送り直す。
    public mutating func requested(at time: TimeInterval) {
        isRequested = true
        deadline = min(deadline ?? .infinity, time + Self.interval)
    }

    /// `deadline` になったら呼ぶ。今送り直すなら true を返し、`presentationTimeMicros` を送り直したフレームとして覚える。
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

    /// 符号化したフレームが出てきたら呼ぶ。
    public mutating func encoded(presentationTimeMicros: Int64, bytes: Int) {
        guard presentationTimeMicros == pendingMicros else { return }
        pendingMicros = nil
        refreshes += 1
        if bytes < Self.settledBytes {
            isSettled = true
        }
    }
}
