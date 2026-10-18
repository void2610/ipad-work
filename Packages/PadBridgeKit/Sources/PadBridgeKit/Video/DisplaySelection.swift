/// Host が iPad に映す画面を決める。映せる画面の一覧と、今映している画面を持つ。
public struct DisplaySelection: Sendable, Equatable {
    public private(set) var displays: [RemoteDisplay] = []
    public private(set) var shownID: UInt32?

    public init() {}

    public struct Update: Sendable, Equatable {
        /// 映す画面が替わった。取り込みと、タッチを届ける画面を替える。
        public var isShownChanged: Bool
        /// 一覧か映す画面が変わったので、iPad に知らせ直す。
        public var needsAnnouncement: Bool
    }

    public enum Switch: Sendable, Equatable {
        case switched
        case alreadyShown
        /// 一覧にない (メニューを開いている間に外れた) 画面。iPad は選んだ画面を先に映したことにしているので、今の一覧を知らせ直す。
        case missing
    }

    public var hasMultipleDisplays: Bool {
        displays.count > 1
    }

    public func contains(_ id: UInt32) -> Bool {
        displays.contains { $0.id == id }
    }

    /// iPad に送る知らせ。映す画面が決まっていなければ nil。
    public var announcement: ControlMessage? {
        shownID.map { .displays(displays, shownID: $0) }
    }

    /// 画面の一覧を読み直した。`preferred` は覚えている画面で、外れていてもよい。外れている間はメインディスプレイを映し、戻ればまたその画面を映す。
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

    /// 映している画面を取り込めないときに、メインディスプレイへ落とす。替わったら true。
    public mutating func fallBackToMain() -> Bool {
        guard let main = displays.first(where: { $0.placement == .main })?.id, main != shownID else { return false }
        shownID = main
        return true
    }
}
