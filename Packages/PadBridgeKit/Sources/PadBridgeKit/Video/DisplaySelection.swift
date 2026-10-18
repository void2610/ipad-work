/// Host が iPad に表示するディスプレイを決める。表示可能なディスプレイの一覧と、現在表示中のディスプレイを持つ。
public struct DisplaySelection: Sendable, Equatable {
    public private(set) var displays: [RemoteDisplay] = []
    public private(set) var shownID: UInt32?

    public init() {}

    public struct Update: Sendable, Equatable {
        /// 表示するディスプレイが変わった。キャプチャとタッチの送り先のディスプレイを切り替える。
        public var isShownChanged: Bool
        /// 一覧か表示するディスプレイが変わったので、iPad に再通知する。
        public var needsAnnouncement: Bool
    }

    public enum Switch: Sendable, Equatable {
        case switched
        case alreadyShown
        /// 一覧にない (メニューを開いている間に外れた) ディスプレイ。iPad は選んだディスプレイを先に表示したことにしているので、現在の一覧を再通知する。
        case missing
    }

    public var hasMultipleDisplays: Bool {
        displays.count > 1
    }

    public func contains(_ id: UInt32) -> Bool {
        displays.contains { $0.id == id }
    }

    /// iPad に送る通知。表示するディスプレイが決まっていなければ nil。
    public var announcement: ControlMessage? {
        shownID.map { .displays(displays, shownID: $0) }
    }

    /// ディスプレイの一覧を再取得した。`preferred` は記憶しているディスプレイで、外れていてもよい。外れている間はメインディスプレイを表示し、戻ればそのディスプレイに戻す。
    public mutating func update(_ newDisplays: [RemoteDisplay], preferred: UInt32?) -> Update {
        let previous = self
        displays = newDisplays
        shownID = RemoteDisplay.shown(preferred: preferred, in: newDisplays)
        return Update(isShownChanged: shownID != previous.shownID, needsAnnouncement: self != previous)
    }

    public mutating func switchTo(_ id: UInt32) -> Switch {
        guard contains(id) else { return .missing }
        guard id != shownID else { return .alreadyShown }
        shownID = id
        return .switched
    }

    /// 表示中のディスプレイをキャプチャできないときに、メインディスプレイへ切り替える。変わったら true。
    public mutating func fallBackToMain() -> Bool {
        guard let main = displays.first(where: { $0.placement == .main })?.id, main != shownID else { return false }
        shownID = main
        return true
    }
}
