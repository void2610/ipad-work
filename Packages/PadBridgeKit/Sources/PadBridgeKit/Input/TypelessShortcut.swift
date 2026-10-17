import Foundation

/// Typeless の設定に書かれたショートカット ("LeftCtrl+Fn" など) を、押す順のキー列に読み替える。
public struct TypelessShortcut: Equatable, Sendable {
    public struct Key: Equatable, Sendable {
        public var keyCode: UInt16
        /// 修飾キーなら CGEventFlags のビット (左右を区別するビットを含む)。修飾キーでなければ 0。
        public var flagMask: UInt64

        public var isModifier: Bool { flagMask != 0 }
    }

    public struct KeyEvent: Equatable, Sendable {
        public var keyCode: UInt16
        public var isDown: Bool
        public var isModifier: Bool
        /// このイベントの時点で押されている修飾キー全体の CGEventFlags。
        public var flags: UInt64
    }

    // CGEventFlags の各ビット。iOS からも単体テストできるよう CoreGraphics の型を使わずに持つ
    static let shift: UInt64 = 0x20000
    static let control: UInt64 = 0x40000
    static let option: UInt64 = 0x80000
    static let command: UInt64 = 0x100000
    static let function: UInt64 = 0x800000
    // 実際のキーボードは左右どちらの修飾キーかを下位ビット (IOLLEvent.h の NX_DEVICE*KEYMASK) でも知らせる。
    // Typeless は Left Ctrl と Right Ctrl をこのビットで区別するので、載せないと Left Ctrl が押されたと認識しない
    static let leftControl: UInt64 = 0x1
    static let leftShift: UInt64 = 0x2
    static let rightShift: UInt64 = 0x4
    static let leftCommand: UInt64 = 0x8
    static let rightCommand: UInt64 = 0x10
    static let leftOption: UInt64 = 0x20
    static let rightOption: UInt64 = 0x40
    static let rightControl: UInt64 = 0x2000
    // 合成ではなく実際の入力から来たイベントに付くビット
    static let nonCoalesced: UInt64 = 0x100

    public static let typelessDefault = TypelessShortcut("LeftCtrl+Fn")!

    public let keys: [Key]

    public init?(_ text: String) {
        let keys = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.map(Self.key(named:))
        guard !keys.isEmpty, keys.allSatisfy({ $0 != nil }) else { return nil }
        self.keys = keys.compactMap(\.self)
    }

    /// 押すときは並び順に、離すときは逆順に送るイベント列。
    public func events(isDown: Bool) -> [KeyEvent] {
        var flags: UInt64 = isDown ? 0 : keys.reduce(0) { $0 | $1.flagMask }
        let ordered = isDown ? keys : keys.reversed()
        return ordered.map { key in
            if key.isModifier {
                flags = isDown ? flags | key.flagMask : flags & ~key.flagMask
            }
            return KeyEvent(keyCode: key.keyCode, isDown: isDown, isModifier: key.isModifier, flags: flags | Self.nonCoalesced)
        }
    }

    private static func key(named name: String) -> Key? {
        let modifiers: [String: Key] = [
            "leftctrl": Key(keyCode: 0x3B, flagMask: control | leftControl), "ctrl": Key(keyCode: 0x3B, flagMask: control | leftControl),
            "control": Key(keyCode: 0x3B, flagMask: control | leftControl), "rightctrl": Key(keyCode: 0x3E, flagMask: control | rightControl),
            "leftshift": Key(keyCode: 0x38, flagMask: shift | leftShift), "shift": Key(keyCode: 0x38, flagMask: shift | leftShift),
            "rightshift": Key(keyCode: 0x3C, flagMask: shift | rightShift),
            "leftalt": Key(keyCode: 0x3A, flagMask: option | leftOption), "alt": Key(keyCode: 0x3A, flagMask: option | leftOption),
            "leftoption": Key(keyCode: 0x3A, flagMask: option | leftOption), "option": Key(keyCode: 0x3A, flagMask: option | leftOption),
            "rightalt": Key(keyCode: 0x3D, flagMask: option | rightOption), "rightoption": Key(keyCode: 0x3D, flagMask: option | rightOption),
            "leftcmd": Key(keyCode: 0x37, flagMask: command | leftCommand), "cmd": Key(keyCode: 0x37, flagMask: command | leftCommand),
            "leftcommand": Key(keyCode: 0x37, flagMask: command | leftCommand), "command": Key(keyCode: 0x37, flagMask: command | leftCommand),
            "rightcmd": Key(keyCode: 0x36, flagMask: command | rightCommand), "rightcommand": Key(keyCode: 0x36, flagMask: command | rightCommand),
            "fn": Key(keyCode: 0x3F, flagMask: function), "function": Key(keyCode: 0x3F, flagMask: function),
            "space": Key(keyCode: 0x31, flagMask: 0),
        ]
        if let key = modifiers[name] {
            return key
        }
        guard name.count == 1, let character = name.uppercased().unicodeScalars.first,
              let usage = letterUsage(character), let keyCode = KeyboardMapping.macVirtualKeyCode(forHIDUsage: usage)
        else { return nil }
        return Key(keyCode: keyCode, flagMask: 0)
    }

    private static func letterUsage(_ character: Unicode.Scalar) -> Int? {
        switch character.value {
        case 0x41 ... 0x5A: Int(character.value - 0x41) + 0x04 // A〜Z
        case 0x31 ... 0x39: Int(character.value - 0x31) + 0x1E // 1〜9
        case 0x30: 0x27 // 0
        default: nil
        }
    }
}
