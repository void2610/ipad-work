import Foundation

/// バーの ⌘ ⌥ ⌃ ⇧ ボタン。押すと次の 1 回にだけ効き、続けて 2 回押すと固定される (iPadOS の Shift と同じ)。
public struct ModifierLatch: Sendable {
    public enum State: Equatable, Sendable {
        case off
        case once
        case locked
    }

    public static let doubleTapInterval: TimeInterval = 0.4
    private var states: [UInt8: State] = [:]
    private var lastTap: [UInt8: TimeInterval] = [:]

    public init() {}

    public func state(of modifier: KeyModifiers) -> State {
        states[modifier.rawValue] ?? .off
    }

    /// 現在の操作に付与する修飾キー。
    public var active: KeyModifiers {
        states.reduce(into: KeyModifiers()) { result, entry in
            if entry.value != .off { result.insert(KeyModifiers(rawValue: entry.key)) }
        }
    }

    public mutating func tap(_ modifier: KeyModifiers, at time: TimeInterval) {
        let key = modifier.rawValue
        let isDoubleTap = lastTap[key].map { time - $0 <= Self.doubleTapInterval } ?? false
        lastTap[key] = time
        switch state(of: modifier) {
        case .off:
            states[key] = .once
        case .once:
            states[key] = isDoubleTap ? .locked : .off
        case .locked:
            states[key] = .off
        }
    }

    /// キーやクリックを 1 回送ったあとに呼ぶ。1 回限りのものは解除され、固定したものは残る。
    public mutating func consume() {
        for (key, state) in states where state == .once {
            states[key] = .off
        }
    }
}

/// Mac 側で、押されている修飾キーを保持する。マウスのイベントにも付与しないと ⌘クリックや ⇧クリックにならない。
public struct HeldModifiers: Sendable {
    private var keyCodes: Set<UInt16> = []

    public init() {}

    public var modifiers: KeyModifiers {
        keyCodes.reduce(into: KeyModifiers()) { result, keyCode in
            switch keyCode {
            case 0x38, 0x3C: result.insert(.shift)
            case 0x3B, 0x3E: result.insert(.control)
            case 0x3A, 0x3D: result.insert(.option)
            case 0x37, 0x36: result.insert(.command)
            default: break
            }
        }
    }

    /// マウスのイベントに付与する CGEventFlags の生の値。
    public var mouseEventFlags: UInt64 {
        KeyboardMapping.eventFlags(modifiers: modifiers, macVirtualKeyCode: 0)
    }

    /// 修飾キーでないキーのイベントに、押されている修飾キーを付与する。
    /// iPadOS は ⌘. のように、押している修飾キーをキーの情報から外して渡すことがあり、そのままだと Mac には . だけが届く。
    public func keyEvent(usage: Int, isDown: Bool, modifiers: KeyModifiers) -> MacKeyEvent? {
        guard let event = MacKeyEvent(usage: usage, isDown: isDown, modifiers: modifiers), !event.isFlagsChanged else {
            return MacKeyEvent(usage: usage, isDown: isDown, modifiers: modifiers)
        }
        return MacKeyEvent(usage: usage, isDown: isDown, modifiers: modifiers.union(self.modifiers))
    }

    public mutating func apply(_ event: MacKeyEvent) {
        guard event.isFlagsChanged else { return }
        if event.isDown {
            keyCodes.insert(event.keyCode)
        } else {
            keyCodes.remove(event.keyCode)
        }
    }

    public mutating func removeAll() {
        keyCodes.removeAll()
    }
}

extension RemoteKeys {
    static let modifierUsages: [(KeyModifiers, Int)] = [(.command, 0xE3), (.option, 0xE2), (.control, 0xE0), (.shift, 0xE1)]

    /// 修飾キーを押してから操作を送り、最後に離す。キーにもクリックにも同じ形で適用できる。
    public static func withModifiers(_ modifiers: KeyModifiers, _ messages: [ControlMessage]) -> [ControlMessage] {
        guard !modifiers.isEmpty else { return messages }
        let used = modifierUsages.filter { modifiers.contains($0.0) }
        var held: KeyModifiers = []
        var downs: [ControlMessage] = []
        for (modifier, usage) in used {
            held.insert(modifier)
            downs.append(.key(usage: usage, isDown: true, modifiers: held))
        }
        let body = messages.map { message -> ControlMessage in
            guard case let .key(usage, isDown, keyModifiers) = message else { return message }
            return .key(usage: usage, isDown: isDown, modifiers: keyModifiers.union(modifiers))
        }
        var ups: [ControlMessage] = []
        for (modifier, usage) in used.reversed() {
            held.remove(modifier)
            ups.append(.key(usage: usage, isDown: false, modifiers: held))
        }
        return downs + body + ups
    }

    /// ソフトウェアキーボードで入力した文字列。英数字と空白はキーとして、記号や日本語は文字として送る (記号は US と JIS の配列でキーの位置が違うため)。
    /// ただし、どちらの配列でも同じ位置にある記号はキーとして送り、かなモードの Mac の日本語入力で「ー」「、」「。」などに変換させる。
    public static func typed(_ text: String, modifiers: KeyModifiers = []) -> [ControlMessage] {
        var messages: [ControlMessage] = []
        var pendingText = ""
        func flushText() {
            if !pendingText.isEmpty {
                messages.append(.insertText(pendingText))
                pendingText = ""
            }
        }
        for character in text {
            if let (usage, needsShift) = keyUsage(for: character) {
                flushText()
                messages += withModifiers(needsShift ? modifiers.union(.shift) : modifiers, tap(usage: usage))
            } else if character == "\n" {
                flushText()
                messages += withModifiers(modifiers, tap(usage: 0x28))
            } else {
                pendingText.append(character)
            }
        }
        flushText()
        return messages
    }

    /// ハードウェアキーボードのショートカット (`input` は修飾キーと一緒に押した文字) を、修飾キーを付けたキーの押下・解放にする。
    /// 修飾キー自体の押下・解放は、押したときにそのまま Mac へ送っているので含めない。送れない文字なら空。
    public static func shortcut(_ input: String, modifiers: KeyModifiers) -> [ControlMessage] {
        guard input.count == 1, let character = input.first, let (usage, needsShift) = keyUsage(for: character) else { return [] }
        return tap(usage: usage, modifiers: needsShift ? modifiers.union(.shift) : modifiers)
    }

    static func keyUsage(for character: Character) -> (usage: Int, needsShift: Bool)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x61 ... 0x7A: return (Int(scalar.value - 0x61) + 0x04, false) // a〜z
        case 0x41 ... 0x5A: return (Int(scalar.value - 0x41) + 0x04, true) // A〜Z
        case 0x31 ... 0x39: return (Int(scalar.value - 0x31) + 0x1E, false) // 1〜9
        case 0x30: return (0x27, false) // 0
        case 0x20: return (0x2C, false) // 空白
        case 0x09: return (0x2B, false) // Tab
        case 0x2D: return (0x2D, false) // - (かなモードでは「ー」)
        case 0x2C: return (0x36, false) // , (かなモードでは「、」)
        case 0x2E: return (0x37, false) // . (かなモードでは「。」)
        case 0x2F: return (0x38, false) // / (かなモードでは「・」)
        case 0x21: return (0x1E, true) // !
        case 0x3F: return (0x38, true) // ?
        default: return nil
        }
    }
}

/// バーの修飾キーを、クリックやドラッグに適用する。ボタンを押す前に修飾キーを押し、離したあとで修飾キーを離す。ドラッグは押してから離すまで続くので、送る単位をまたいで保持する。
public struct PointerModifierHold: Sendable {
    private var held: KeyModifiers = []

    public init() {}

    /// 修飾キーを使ったら `didUseModifiers` が true になる。
    public mutating func wrap(_ messages: [ControlMessage], modifiers: KeyModifiers) -> (messages: [ControlMessage], didUseModifiers: Bool) {
        var result: [ControlMessage] = []
        var didUse = false
        for message in messages {
            guard case let .mouseButton(_, isDown, _) = message else {
                result.append(message)
                continue
            }
            if isDown, held.isEmpty, !modifiers.isEmpty {
                let wrapped = RemoteKeys.withModifiers(modifiers, [])
                result += wrapped.prefix(wrapped.count / 2)
                held = modifiers
                didUse = true
            }
            result.append(message)
            if !isDown, !held.isEmpty {
                let wrapped = RemoteKeys.withModifiers(held, [])
                result += wrapped.suffix(wrapped.count / 2)
                held = []
            }
        }
        return (result, didUse)
    }
}
