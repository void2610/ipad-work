import CoreGraphics
import Foundation

/// Mac につながっている画面のうち、iPad に映せるもの。
public struct RemoteDisplay: Codable, Sendable, Equatable, Identifiable {
    /// メインディスプレイから見た置き場所。名前を持たない画面や、同じ名前の画面を見分けるのに使う。
    public enum Placement: String, Codable, Sendable {
        case main
        case left
        case right
        case above
        case below
    }

    /// Mac の画面を読み取った値。
    public struct Source: Sendable, Equatable {
        public var id: UInt32
        public var name: String
        /// Mac の画面の座標 (メインディスプレイの左上が原点、下が正)。
        public var bounds: CGRect
        public var isMain: Bool
        /// 別の画面と同じものを映している (ミラーリングの 2 台目以降)。
        public var isMirror: Bool

        public init(id: UInt32, name: String, bounds: CGRect, isMain: Bool, isMirror: Bool) {
            self.id = id
            self.name = name
            self.bounds = bounds
            self.isMain = isMain
            self.isMirror = isMirror
        }
    }

    /// Mac の `CGDirectDisplayID`。
    public var id: UInt32
    public var name: String
    public var placement: Placement

    public static let unnamed = "名称不明のディスプレイ"

    public init(id: UInt32, name: String, placement: Placement) {
        self.id = id
        self.name = name
        self.placement = placement
    }

    /// iPad のメニューに出す名前。
    public var label: String {
        let place = switch placement {
        case .main: "メインディスプレイ"
        case .left: "メインディスプレイの左"
        case .right: "メインディスプレイの右"
        case .above: "メインディスプレイの上"
        case .below: "メインディスプレイの下"
        }
        return "\(name) (\(place))"
    }

    /// 映せる画面を、Mac の配置どおり左から並べる。ミラーリングの 2 台目以降は同じものが映るので除く。
    public static func list(_ sources: [Source]) -> [RemoteDisplay] {
        let shown = sources.filter { !$0.isMirror }
        guard let main = shown.first(where: \.isMain) ?? shown.first else { return [] }
        let displays = shown
            .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
            .map { source in
                RemoteDisplay(
                    id: source.id,
                    name: source.name.isEmpty ? unnamed : source.name,
                    placement: source.id == main.id ? .main : placement(of: source.bounds, from: main.bounds)
                )
            }
        // 同じ機種を同じ側に並べると名前も置き場所も同じになるので、左から番号を付けて見分ける
        let counts = Dictionary(displays.map { ($0.label, 1) }, uniquingKeysWith: +)
        var numbers: [String: Int] = [:]
        return displays.map { display in
            guard counts[display.label, default: 0] > 1 else { return display }
            let number = numbers[display.label, default: 0] + 1
            numbers[display.label] = number
            var numbered = display
            numbered.name += " \(number)"
            return numbered
        }
    }

    /// 映す画面。選ばれた画面がつながっていればそれを、なければメインディスプレイを映す。
    public static func shown(preferred: UInt32?, in displays: [RemoteDisplay]) -> UInt32? {
        if let preferred, displays.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return (displays.first { $0.placement == .main } ?? displays.first)?.id
    }

    /// ウィンドウが載っている画面。画面をまたいでいるときは、重なりの一番大きい画面にする。どの画面にも重ならなければ nil。
    public static func showing(window: CGRect, displays: [UInt32: CGRect]) -> UInt32? {
        let overlaps = displays.compactMap { id, bounds -> (id: UInt32, area: CGFloat)? in
            let shared = window.intersection(bounds)
            guard !shared.isNull, shared.width > 0, shared.height > 0 else { return nil }
            return (id, shared.width * shared.height)
        }
        return overlaps.max { ($0.area, $1.id) < ($1.area, $0.id) }?.id
    }

    /// ウィンドウを別の画面へ移すときの、新しい位置と大きさ。`source` と `destination` は、それぞれの画面のメニューバーと Dock を除いた範囲。
    /// 元の画面の中での置き場所の割合 (左寄り・中央など) を保ち、移す先に収まらなければ縮める。
    public static func moved(window: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, destination.width), height: min(window.height, destination.height))
        func place(_ origin: CGFloat, _ length: CGFloat, in from: (min: CGFloat, length: CGFloat), to: (min: CGFloat, length: CGFloat), newLength: CGFloat) -> CGFloat {
            let room = from.length - length
            let ratio = room > 0 ? min(max((origin - from.min) / room, 0), 1) : 0.5
            return to.min + ratio * (to.length - newLength)
        }
        return CGRect(
            x: place(window.minX, window.width, in: (source.minX, source.width), to: (destination.minX, destination.width), newLength: size.width),
            y: place(window.minY, window.height, in: (source.minY, source.height), to: (destination.minY, destination.height), newLength: size.height),
            width: size.width,
            height: size.height
        )
    }

    /// 中心どうしのずれが大きい向きで、上下か左右かを決める。
    static func placement(of bounds: CGRect, from main: CGRect) -> Placement {
        let dx = bounds.midX - main.midX
        let dy = bounds.midY - main.midY
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .above : .below
    }
}
