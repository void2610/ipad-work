import Foundation

public enum ConnectionRole: String, Codable, Sendable {
    case control
    case video
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
}

/// Mac のディスプレイに対する位置。左上を原点に 0...1 で表す。
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    /// 受け取った値も丸める。範囲外の値が届くと、Mac は隣のディスプレイの見えない位置を押してしまう
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: container.decode(Double.self, forKey: .x), y: container.decode(Double.self, forKey: .y))
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
    /// iPad のマイクの音声を Mac の入力デバイスとして渡せるか (システムオーディオ録音の許可)。確認前は true。
    public var canRelayMicrophone: Bool
    /// Typeless が「PadBridge iPad マイク」を読み取ろうとして、システムオーディオ録音の許可がなく拒否された。
    /// タップを含む入力デバイスを読み取るには、読み取る側の Typeless にもこの許可が必要で、ユーザーがシステム設定で追加するしかない。
    public var typelessCannotReadPadMicrophone: Bool
    /// iPad から音声入力を開始したのに、Typeless が「PadBridge iPad マイク」以外のマイクで録音していた。
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
    /// ディスプレイの幅・高さに対する割合で表した、指の移動量。
    case scroll(dx: Double, dy: Double)
    /// `usage` は USB HID の Keyboard/Keypad ページの usage。
    case key(usage: Int, isDown: Bool, modifiers: KeyModifiers)
    case insertText(String)
    /// Mac の Typeless で音声入力を始める (true) か、終える (false) か。
    case voiceInput(isActive: Bool)
    /// Mac の Typeless が現在音声入力中か。Mac から iPad へ、接続時と変化時に通知する。
    case voiceInputState(isActive: Bool)
    /// 3 本指でスワイプした向き。Mac はトラックパッドの 3 本指スワイプと同じ操作をする。
    case desktopSwipe(TouchInterpreter.SwipeDirection)
    case requestKeyFrame
    /// Mac から iPad へ、映像用の接続で。受信したフレームごとに `videoFrameReceived` を返すよう要求する。
    /// 古い Mac に未知のメッセージを毎フレーム送らないよう、要求されたときだけ返す。
    case acknowledgeVideoFrames
    /// iPad から Mac へ、映像用の接続で。このフレームを受信した。Mac は ACK が未達のフレーム数で、次を送るかを決める。
    case videoFrameReceived(presentationTimeMicros: Int64)
    /// Mac から iPad へ。回線が遅いので映像の画質 (ビットレート) を大きく下げているか。変わったときに通知する。
    case videoQuality(isReduced: Bool)
    /// Mac から iPad へ。映像を送っている間、2 秒ごとに送る映像の状態。iPad の「接続の状態」に表示する。
    case videoStats(VideoStats)
    /// iPad から Mac へ。受信したい映像のフレームレート (`PreferredFrameRate`)。接続時に 60 でなければ送り、変化時にも送る。
    case videoFrameRate(Int)
    /// iPad から Mac へ。映像として送ってほしいディスプレイの範囲。拡大している間は見えている範囲だけを高解像度で送ってもらう。
    case videoRegion(VideoRegion)
    /// iPad から Mac へ。Mac で再生しているサウンドを iPad で再生するか。iPad で再生している間は、Mac のスピーカーからは出さない。
    case macAudio(isEnabled: Bool)
    /// iPad から Mac へ。Mac のサウンドをこの形式で送ってほしい。`macAudio(isEnabled:)` より前に送る。この形式を知らない古い Mac は無圧縮のまま送る。
    case macAudioCodec(MacAudio.Codec)
    /// Mac から iPad へ。表示できるディスプレイと、現在表示中のディスプレイ。接続時と変化時に通知する。
    case displays([RemoteDisplay], shownID: UInt32)
    /// iPad から Mac へ。表示するディスプレイを選ぶ。Mac は選ばれたディスプレイを記憶し、そのディスプレイが接続されている間はそれを表示する。
    case selectDisplay(id: UInt32)
    /// iPad から Mac へ。最前面のウィンドウをこのディスプレイへ移し、そのディスプレイを表示する。ディスプレイをまたいでドラッグできない代わり。
    case moveFrontWindow(toDisplay: UInt32)
    /// iPad から Mac へ。Dock を表示してキーボードで選べるようにする (ディスプレイの下端から上へスワイプしたとき)。
    /// Dock は 1 台のディスプレイにしかないので、表示していないディスプレイにあれば Mac はそのディスプレイを表示してから出す。
    case showDock
    /// iPad から Mac へ。iPad がバックグラウンドに移るので、押したままのキーとボタンを離す。iPadOS に奪われて解放通知が届かなかったキーを Mac に残さない。
    case releaseHeldInput
    /// Mac から iPad へ。Mac の文字入力が英数とかなのどちらか。接続時と変化時に通知する。
    case macInputMode(MacInputMode)
    /// 互いに、ビルドしたコミットを通知する (`BuildCommit`)。Host は iPad が接続したとき、iPad は welcome を受信したときに送る。
    case buildCommit(String)
    /// Mac から iPad へ。Mac の画面がロックされているか。接続時にロックされていれば送り、変化時にも送る。
    case macScreenLocked(Bool)
    // 以下は Mac の中で、Host とヘルパーアプリ「PadBridge マイク」がやり取りする
    /// ヘルパーアプリが Host に接続したら最初に送る。Host が起動時に渡したトークンで、他のプロセスからの接続と区別する。
    case microphoneRelayHello(token: String)
    /// Host からヘルパーアプリへ。iPad から音声入力を開始するか (true)、終了したか (false)。
    case microphoneRelay(isListening: Bool)
    /// ヘルパーアプリから Host へ。音声入力の準備ができたので Typeless を起動してよい。既定の入力を iPad のマイクにしたか。
    case microphoneRelayReady(isUsingPadMicrophone: Bool)
    /// ヘルパーアプリから Host へ。システムオーディオ録音の許可があるか。
    case microphoneRelayStatus(isAuthorized: Bool)
    /// Host からヘルパーアプリへ。iPad で音声入力を停止した。停止時点までの音声を再生し終えたら通知する。
    case microphoneRelayFinish
    /// ヘルパーアプリから Host へ。停止時点までの音声を再生し終えたので、Typeless を停止してよい。
    case microphoneRelayFinished
}
