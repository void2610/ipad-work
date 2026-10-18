/// iPad から届いた音声入力の開始・完了の要求を、届いた順に番号で覚える。後から届いた要求が優先で、古い要求の続き (補助アプリの返事、押し直し) は捨てる。
public struct VoiceInputRequests: Sendable, Equatable {
    public private(set) var latest = 0
    /// 始めさせたが、Typeless が聞き取りを始めたのをまだ確かめていない要求。
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

    /// 始めさせた要求が、聞き取りを始めた (または始めるのをあきらめた)。
    public mutating func settle(_ request: Int) {
        if pendingStart == request {
            pendingStart = nil
        }
    }

    /// iPad とのつながりが切れた。待っている要求の続きで Typeless を始めない。
    public mutating func cancelAll() {
        latest += 1
        pendingStart = nil
    }

    /// Typeless の聞き取りが終わったことを iPad に知らせるか。
    /// 止めた直後に iPad でまた始めたときは、前の聞き取りの終わりを知らせると iPad が始めたばかりのマイクを止めてしまうので、知らせない。
    public var announcesStop: Bool {
        pendingStart == nil
    }
}
