/// iPad から届いた音声入力の開始・完了の要求を、届いた順に番号で記憶する。後から届いた要求を優先し、古い要求の続き (ヘルパーアプリの応答、押し直し) は破棄する。
public struct VoiceInputRequests: Sendable, Equatable {
    public private(set) var latest = 0
    /// 開始させたが、Typeless が音声入力を始めたのをまだ確認していない要求。
    public private(set) var pendingStart: Int?

    public init() {}

    /// 要求の番号を返す。
    public mutating func receive(isActive: Bool) -> Int {
        latest += 1
        pendingStart = isActive ? latest : nil
        return latest
    }

    public func isCurrent(_ request: Int) -> Bool {
        request == latest
    }

    /// 開始させた要求が、音声入力を開始した (または開始を断念した)。
    public mutating func settle(_ request: Int) {
        if pendingStart == request {
            pendingStart = nil
        }
    }

    /// iPad との接続が切れた。待機中の要求の続きで Typeless を開始しない。
    public mutating func cancelAll() {
        latest += 1
        pendingStart = nil
    }

    /// Typeless の音声入力が終わったことを iPad に通知するか。
    /// 停止した直後に iPad でまた開始したときは、前回の音声入力の終了を通知すると iPad が開始したばかりのマイクを止めてしまうので、通知しない。
    public var announcesStop: Bool {
        pendingStart == nil
    }
}
