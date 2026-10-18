import Foundation

/// Mac 側で、3 本指スワイプの向きをトラックパッドと同じ操作に変換したもの。
public enum DesktopAction: Equatable, Sendable {
    /// スペースを右隣 (true) か左隣 (false) へ切り替える。
    case switchSpace(toRight: Bool)
    /// Control+矢印のショートカット。上は Mission Control、下はアプリケーションウインドウ。
    case controlArrow(usage: Int)

    /// トラックパッドと同じく、左へスワイプすると右隣のスペースへ移る。
    public init(swipe direction: TouchInterpreter.SwipeDirection) {
        switch direction {
        case .left: self = .switchSpace(toRight: true)
        case .right: self = .switchSpace(toRight: false)
        case .up: self = .controlArrow(usage: KeyboardMapping.ArrowUsage.up)
        case .down: self = .controlArrow(usage: KeyboardMapping.ArrowUsage.down)
        }
    }
}

/// iPad のボタンやジェスチャーから Mac へ送る、キー操作の並び。
public enum RemoteKeys {
    public static let leftControl = 0xE0
    public static let leftCommand = 0xE3
    public static let tab = 0x2B
    public static let f3 = 0x3C

    public static func tap(usage: Int, modifiers: KeyModifiers = []) -> [ControlMessage] {
        [.key(usage: usage, isDown: true, modifiers: modifiers), .key(usage: usage, isDown: false, modifiers: modifiers)]
    }

    /// Control を押したまま矢印キーを押す。トラックパッドの 3 本指スワイプと同じく、デスクトップの切り替えや Mission Control になる。
    public static func controlArrow(usage: Int) -> [ControlMessage] {
        withControl(tap(usage: usage, modifiers: [.control]))
    }

    /// macOS の「Dock にフォーカスを移動」(既定は Control+F3)。Dock を自動的に隠していても表示される。
    /// iPad の指ではカーソルをディスプレイの下端に置いたままにできず、Dock を表示できないため、こちらで表示する。
    public static func focusDock() -> [ControlMessage] {
        withControl(tap(usage: f3, modifiers: [.control]))
    }

    private static func withControl(_ messages: [ControlMessage]) -> [ControlMessage] {
        [.key(usage: leftControl, isDown: true, modifiers: [.control])]
            + messages
            + [.key(usage: leftControl, isDown: false, modifiers: [])]
    }
}

/// Command+Tab のアプリ切り替え。タップのたびに Command を押したまま Tab を送り、一定時間タップがなければ Command を離して確定する。
/// iPadOS がハードウェアキーボードの Command+Tab を先に処理してしまうため、ボタンで代替する。
public struct AppSwitcher: Sendable {
    public static let commitDelay: TimeInterval = 1
    private var lastTap: TimeInterval?

    public init() {}

    public var isSwitching: Bool { lastTap != nil }

    public mutating func tap(at time: TimeInterval) -> [ControlMessage] {
        let pressCommand: [ControlMessage] = lastTap == nil ? [.key(usage: RemoteKeys.leftCommand, isDown: true, modifiers: [.command])] : []
        lastTap = time
        return pressCommand + RemoteKeys.tap(usage: RemoteKeys.tab, modifiers: [.command])
    }

    /// 最後のタップから確定までの時間が過ぎていれば Command を離す。
    public mutating func commitIfDue(at time: TimeInterval) -> [ControlMessage] {
        guard let lastTap, time - lastTap >= Self.commitDelay else { return [] }
        return commit()
    }

    /// バックグラウンドに移るときなど、待たずに確定させる。
    public mutating func commit() -> [ControlMessage] {
        guard lastTap != nil else { return [] }
        lastTap = nil
        return [.key(usage: RemoteKeys.leftCommand, isDown: false, modifiers: [])]
    }
}

/// Mac で合成するキーイベント 1 つ分。修飾キーは押下ではなく修飾状態の変化として送らないと、アプリが Command などを認識しない。
public struct MacKeyEvent: Equatable, Sendable {
    public var keyCode: UInt16
    public var isDown: Bool
    public var isFlagsChanged: Bool
    public var flags: UInt64

    public init?(usage: Int, isDown: Bool, modifiers: KeyModifiers) {
        guard let keyCode = KeyboardMapping.macVirtualKeyCode(forHIDUsage: usage) else { return nil }
        self.keyCode = keyCode
        self.isDown = isDown
        isFlagsChanged = KeyboardMapping.isModifier(macVirtualKeyCode: keyCode)
        flags = KeyboardMapping.eventFlags(modifiers: modifiers, macVirtualKeyCode: keyCode)
    }
}
