import Foundation

public enum ConnectionRole: String, Codable, Sendable {
    case control
    case video
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
}

/// Mac の画面に対する位置。左上を原点に 0...1 で表す。
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public struct HostStatus: Codable, Sendable, Equatable {
    public var canCaptureScreen: Bool
    public var canControlInput: Bool

    public init(canCaptureScreen: Bool, canControlInput: Bool) {
        self.canCaptureScreen = canCaptureScreen
        self.canControlInput = canControlInput
    }
}

public enum ControlMessage: Codable, Sendable, Equatable {
    case hello(role: ConnectionRole, deviceName: String, maxVideoWidth: Int, maxVideoHeight: Int)
    case welcome(hostName: String, status: HostStatus)
    case hostStatus(HostStatus)
    case mouseMove(NormalizedPoint)
    case mouseButton(MouseButton, isDown: Bool, at: NormalizedPoint)
    /// 画面の幅・高さに対する割合で表した、指の移動量。
    case scroll(dx: Double, dy: Double)
    /// `usage` は USB HID の Keyboard/Keypad ページの usage。
    case key(usage: Int, isDown: Bool, modifiers: KeyModifiers)
    case insertText(String)
    /// Mac の Typeless で音声入力を始める (true) か、終える (false) か。
    case voiceInput(isActive: Bool)
    case requestKeyFrame
}
