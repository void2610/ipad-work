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
    /// iPad のマイクの音を Mac の入力デバイスとして渡せるか (システムオーディオの録音の許可)。確かめる前は true。
    public var canRelayMicrophone: Bool
    /// Typeless が「PadBridge iPad マイク」を読もうとして、システムオーディオの録音の許可がないと断られた。
    /// タップを含む入力デバイスを読むには、読む側の Typeless にもこの許可が要り、利用者がシステム設定で加えるしかない。
    public var typelessCannotReadPadMicrophone: Bool
    /// iPad から聞き取りを始めたのに、Typeless が「PadBridge iPad マイク」ではないマイクで録音していた。
    /// このデバイスは Mac の既定の入力になれないので、Typeless のマイクが「自動検出」なら Host が選び直す。
    public var typelessUsesOtherMicrophone: Bool

    public init(
        canCaptureScreen: Bool,
        canControlInput: Bool,
        canRelayMicrophone: Bool = true,
        typelessCannotReadPadMicrophone: Bool = false,
        typelessUsesOtherMicrophone: Bool = false
    ) {
        self.canCaptureScreen = canCaptureScreen
        self.canControlInput = canControlInput
        self.canRelayMicrophone = canRelayMicrophone
        self.typelessCannotReadPadMicrophone = typelessCannotReadPadMicrophone
        self.typelessUsesOtherMicrophone = typelessUsesOtherMicrophone
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
    /// Mac の Typeless が今聞き取っているか。Mac から iPad へ、接続したときと変わったときに知らせる。
    case voiceInputState(isActive: Bool)
    /// 3 本指で払った向き。Mac はトラックパッドの 3 本指スワイプと同じ操作をする。
    case desktopSwipe(TouchInterpreter.SwipeDirection)
    case requestKeyFrame
    /// iPad から Mac へ。映像として送ってほしい画面の範囲。拡大している間は見えている範囲だけを高い解像度で送ってもらう。
    case videoRegion(VideoRegion)
    /// iPad から Mac へ。Mac で鳴っている音を iPad で鳴らすか。鳴らしている間、Mac のスピーカーからは鳴らさない。
    case macAudio(isEnabled: Bool)
    /// Mac から iPad へ。映せる画面と、今映している画面。接続したときと変わったときに知らせる。
    case displays([RemoteDisplay], shownID: UInt32)
    /// iPad から Mac へ。映す画面を選ぶ。Mac は選ばれた画面を覚え、その画面がつながっている間はそれを映す。
    case selectDisplay(id: UInt32)
    /// iPad から Mac へ。手前のウィンドウをこの画面へ移し、その画面を映す。画面をまたいでドラッグできない代わり。
    case moveFrontWindow(toDisplay: UInt32)
    /// iPad から Mac へ。Dock を出してキーボードで選べるようにする (画面の下端から上へ払ったとき)。
    /// Dock は 1 台の画面にしかないので、映していない画面にあれば Mac はその画面を映してから出す。
    case showDock
    /// iPad から Mac へ。iPad が裏に回るので、押したままのキーとボタンを離す。iPadOS に取られて離した知らせが届かなかったキーを Mac に残さない。
    case releaseHeldInput
    /// Mac から iPad へ。Mac の文字入力が英数とかなのどちらか。接続したときと変わったときに知らせる。
    case macInputMode(MacInputMode)
    // 以下は Mac の中で、Host と補助アプリ「PadBridge マイク」がやり取りする
    /// 補助アプリが Host につないだら最初に送る。Host が起動時に渡した合言葉で、他のプロセスからの接続と見分ける。
    case microphoneRelayHello(token: String)
    /// Host から補助アプリへ。iPad から聞き取りを始めるか (true)、終えたか (false)。
    case microphoneRelay(isListening: Bool)
    /// 補助アプリから Host へ。聞き取りの準備ができたので Typeless を起動してよい。既定の入力を iPad のマイクにしたか。
    case microphoneRelayReady(isUsingPadMicrophone: Bool)
    /// 補助アプリから Host へ。システムオーディオの録音の許可があるか。
    case microphoneRelayStatus(isAuthorized: Bool)
    /// Host から補助アプリへ。iPad で聞き取りを止めた。止めたところまでの声を流し終えたら知らせる。
    case microphoneRelayFinish
    /// 補助アプリから Host へ。止めたところまでの声を流し終えたので、Typeless を止めてよい。
    case microphoneRelayFinished
}
