import AppKit
import CoreAudio
import Foundation
import Network
import os
import PadBridgeKit

/// ヘルパーアプリが作成する入力デバイス。
nonisolated enum PadMicrophoneDevice {
    static let uid = "dev.void2610.padbridge.ipad-mic"
    static let name = "PadBridge iPad マイク"

    /// ヘルパーアプリが後始末できずに終了して (強制終了など) 残ったデバイスとタップを削除する。
    /// 残ったものはヘルパーアプリが次に起動するまで消えず、iPad を接続しないとサウンド設定に「PadBridge iPad マイク」が出続けるので、Host の起動時にも削除する。
    static func removeLeftovers() {
        if let device = objects(kAudioHardwarePropertyDevices).first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }) {
            AudioHardwareDestroyAggregateDevice(device)
        }
        for tap in objects(kAudioHardwarePropertyTapList) where tapName(tap) == name {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private static func tapName(_ tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr else { return nil }
        return description?.takeRetainedValue().name
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// ヘルパーアプリ「PadBridge マイク」を起動し、iPad のマイク音声を渡す。ヘルパーアプリがそれを Mac の入力デバイスとして見せる。
/// 音声をキャプチャするプロセスタップにはシステムオーディオ録音の許可が必要だが、ターミナルから起動した Host では Ghostty の許可として要求されて拒否される。
/// Host のバンドル内のヘルパーアプリを LaunchServices で起動すると、許可は PadBridge Host のものとして要求される。
/// Host 自身をアプリとして再起動する必要がないので、画面収録などの許可を取り直す間にディスプレイが表示されなくなることもない。
/// HostServer のキュー上でのみ使う。
nonisolated final class MicrophoneRelay: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "microphone")
    // ヘルパーアプリが応答しないときに、Typeless の起動や完了を待たせ続けない
    private static let readyTimeout: TimeInterval = 1.5
    // ヘルパーアプリは、バッファしている音声 (最大 6 秒) を流し終えるまで待ってから応答する
    private static let finishTimeout: TimeInterval = 8

    private let queue: DispatchQueue
    private let onAuthorizationChange: @Sendable () -> Void
    private let onLateReady: @Sendable (_ isUsingPadMicrophone: Bool) -> Void
    // iPad から音声入力を開始していて、まだ終了していないか。タイムアウト後に届いた応答を、現在の音声入力に反映するかを判定する
    private var isListeningRequested = false
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var channel: MessageChannel?
    // トークンが届くまでの接続。ここで保持しておかないと、受け付けた直後に解放されてトークンを受け取れない
    private var pending: [ObjectIdentifier: MessageChannel] = [:]
    private var isRunning = false
    // 起動してから接続してくるまでの間に、もう 1 つ起動しないようにする
    private var launchedAt: TimeInterval?
    // 起動に連続して失敗した回数。署名などで起動できないときに、iPad が再接続するまで黙って使えないままにしない
    private var launchFailures = 0
    private var pendingReady: (@Sendable (Bool) -> Void)?
    // 音声入力を開始するたびに増やす。前のリクエストのタイムアウトで、次のリクエストの応答待ちを打ち切らないように
    private var readyCount = 0
    private var pendingFinish: (id: Int, done: @Sendable () -> Void)?
    private var finishCount = 0
    private(set) var isKnownUnauthorized = false

    /// `onLateReady` は、音声入力の準備の応答がタイムアウト (`readyTimeout`) を過ぎてから届いたときに、このキュー上で呼ばれる。
    init(queue: DispatchQueue, onAuthorizationChange: @escaping @Sendable () -> Void, onLateReady: @escaping @Sendable (_ isUsingPadMicrophone: Bool) -> Void) {
        self.queue = queue
        self.onAuthorizationChange = onAuthorizationChange
        self.onLateReady = onLateReady
    }

    /// iPad が接続したときに呼ぶ。ヘルパーアプリがまだ動いていなければ起動する。
    func start() {
        isRunning = true
        let now = ProcessInfo.processInfo.systemUptime
        guard channel == nil, launchedAt.map({ now - $0 > 10 }) ?? true else { return }
        if let port = listener?.port {
            launchHelper(port: port)
        } else {
            startListener()
        }
    }

    /// iPad の接続が切れてしばらくたったときに呼ぶ。接続を閉じると、ヘルパーアプリはデバイスを削除して終了する。
    func stop() {
        isRunning = false
        isListeningRequested = false
        finishPendingReady()
        completeFinish()
        channel?.cancel()
        channel = nil
    }

    /// iPad から音声入力を開始するとき、ヘルパーアプリが既定の入力を切り替え終えたら、切り替えたかを `ready` に渡す。ヘルパーアプリがなければすぐに呼ぶ。
    func beginListening(ready: @escaping @Sendable (Bool) -> Void) {
        guard let channel else {
            ready(false)
            return
        }
        finishPendingReady()
        pendingReady = ready
        isListeningRequested = true
        readyCount += 1
        let id = readyCount
        channel.send(.control(.microphoneRelay(isListening: true)))
        queue.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
            guard let self, readyCount == id else { return }
            finishPendingReady()
        }
    }

    func endListening() {
        isListeningRequested = false
        channel?.send(.control(.microphoneRelay(isListening: false)))
    }

    /// iPad で停止したとき、停止時点までの音声をヘルパーアプリが流し終えたら `done` を呼ぶ。ヘルパーアプリがなければすぐに呼ぶ。
    func finishListening(done: @escaping @Sendable () -> Void) {
        guard let channel else {
            done()
            return
        }
        completeFinish()
        finishCount += 1
        let id = finishCount
        pendingFinish = (id, done)
        channel.send(.control(.microphoneRelayFinish))
        queue.asyncAfter(deadline: .now() + Self.finishTimeout) { [weak self] in
            guard let self, pendingFinish?.id == id else { return }
            completeFinish()
        }
    }

    private func completeFinish() {
        let done = pendingFinish?.done
        pendingFinish = nil
        done?()
    }

    func feed(_ samples: Data) {
        channel?.send(.audio(samples))
    }

    private func finishPendingReady(isUsingPadMicrophone: Bool = false) {
        let ready = pendingReady
        pendingReady = nil
        ready?(isUsingPadMicrophone)
    }

    // MARK: - ヘルパーアプリとの接続

    private func startListener() {
        let parameters = NWParameters.padBridge()
        // 同じ Mac のヘルパーアプリだけが接続できるようにする
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        guard let listener = try? NWListener(using: parameters) else {
            Self.logger.error("ヘルパーアプリとの接続を待ち受けられない")
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, case .ready = state, let port = listener?.port else { return }
            if isRunning, channel == nil {
                launchHelper(port: port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func launchHelper(port: NWEndpoint.Port) {
        launchedAt = ProcessInfo.processInfo.systemUptime
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/PadBridge Mic.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // 前の Host から残ったヘルパーアプリには新しい接続先が渡らないので、常に新しく起動する。古い方は接続が切れて自分で終了する
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--port", String(port.rawValue), "--token", token]
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                Self.logger.error("ヘルパーアプリを起動できない: \(error, privacy: .public)")
                guard let self else { return }
                queue.async { self.retryLaunch() }
            }
        }
    }

    private func retryLaunch() {
        launchedAt = nil
        launchFailures += 1
        guard launchFailures <= 3 else { return }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, isRunning, channel == nil else { return }
            start()
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = MessageChannel(connection: connection, queue: queue)
        pending[ObjectIdentifier(channel)] = channel
        // トークンを送らないままの接続を残さない
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel, pending[ObjectIdentifier(channel)] === channel else { return }
            pending[ObjectIdentifier(channel)] = nil
            channel.cancel()
        }
        channel.start(
            onStateChange: { [weak self, weak channel] state in
                switch state {
                case .failed, .cancelled:
                    guard let self, let channel else { return }
                    pending[ObjectIdentifier(channel)] = nil
                    guard channel === self.channel else { return }
                    self.channel = nil
                    finishPendingReady()
                    completeFinish()
                    // ヘルパーアプリが落ちたら、iPad が接続している間は再起動する。落ち続けるときに起動を繰り返し続けないよう、少し待つ
                    if isRunning {
                        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self, isRunning, self.channel == nil else { return }
                            start()
                        }
                    }
                default:
                    break
                }
            },
            onMessage: { [weak self, weak channel] message in
                guard let self, let channel, case let .control(message) = message else { return }
                switch message {
                case let .microphoneRelayHello(token):
                    pending[ObjectIdentifier(channel)] = nil
                    guard token == self.token, isRunning else {
                        channel.cancel()
                        return
                    }
                    self.channel?.cancel()
                    self.channel = channel
                    launchedAt = nil
                    launchFailures = 0
                    Self.logger.notice("ヘルパーアプリと接続した")
                // トークンを確認した接続からのものだけを受け付ける
                case let .microphoneRelayReady(isUsingPadMicrophone) where channel === self.channel:
                    // ヘルパーアプリが起動直後のチェックなどで遅れると、タイムアウトを過ぎてから届く。Typeless はすでに音声入力を始めているので、そのことを伝える
                    if pendingReady == nil, isListeningRequested {
                        onLateReady(isUsingPadMicrophone)
                    }
                    finishPendingReady(isUsingPadMicrophone: isUsingPadMicrophone)
                case .microphoneRelayFinished where channel === self.channel:
                    completeFinish()
                case let .microphoneRelayStatus(isAuthorized) where channel === self.channel:
                    isKnownUnauthorized = !isAuthorized
                    onAuthorizationChange()
                default:
                    break
                }
            }
        )
    }
}
