import AppKit
import Foundation
import Network
import os
import PadBridgeKit

/// 補助アプリ「PadBridge マイク」を起動し、iPad のマイクの音を渡す。補助アプリがそれを Mac の入力デバイスとして見せる。
/// 音を取り出すプロセスタップにはシステムオーディオの録音の許可が要るが、ターミナルから動かした Host では Ghostty の許可として求められて断られる。
/// Host のバンドルの中の補助アプリを LaunchServices で起動すると、許可は PadBridge Host のものとして求められる。
/// Host 自身をアプリとして起動し直す必要がないので、画面収録などの許可を取り直す間に画面が映らなくなることもない。
/// HostServer のキューの上でだけ使う。
/// 補助アプリが作る入力デバイス。
enum PadMicrophoneDevice {
    static let uid = "dev.void2610.padbridge.ipad-mic"
    static let name = "PadBridge iPad マイク"
}

nonisolated final class MicrophoneRelay: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "microphone")
    // 補助アプリが応えないときに、Typeless の起動を待たせ続けない
    private static let readyTimeout: TimeInterval = 1.5

    private let queue: DispatchQueue
    private let onAuthorizationChange: @Sendable () -> Void
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var channel: MessageChannel?
    // 合言葉が届くまでの接続。ここで持っておかないと、受け付けた直後に解放されて合言葉を受け取れない
    private var pending: [ObjectIdentifier: MessageChannel] = [:]
    private var isRunning = false
    // 起動してから接続してくるまでの間に、もう 1 つ起動しないようにする
    private var launchedAt: TimeInterval?
    private var pendingReady: (@Sendable (Bool) -> Void)?
    private(set) var isKnownUnauthorized = false

    init(queue: DispatchQueue, onAuthorizationChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onAuthorizationChange = onAuthorizationChange
    }

    /// iPad がつながったときに呼ぶ。補助アプリを起動する。
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

    /// iPad の接続が切れたときに呼ぶ。接続を閉じると、補助アプリはデバイスを消して終わる。
    func stop() {
        isRunning = false
        finishPendingReady()
        channel?.cancel()
        channel = nil
    }

    /// iPad から聞き取りを始めるとき、補助アプリが既定の入力を切り替え終えたら、切り替えたかを `ready` に渡す。補助アプリがなければすぐに呼ぶ。
    func beginListening(ready: @escaping @Sendable (Bool) -> Void) {
        guard let channel else {
            ready(false)
            return
        }
        finishPendingReady()
        pendingReady = ready
        channel.send(.control(.microphoneRelay(isListening: true)))
        queue.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
            self?.finishPendingReady()
        }
    }

    func endListening() {
        channel?.send(.control(.microphoneRelay(isListening: false)))
    }

    func feed(_ samples: Data) {
        channel?.send(.audio(samples))
    }

    private func finishPendingReady(isUsingPadMicrophone: Bool = false) {
        let ready = pendingReady
        pendingReady = nil
        ready?(isUsingPadMicrophone)
    }

    // MARK: - 補助アプリとの接続

    private func startListener() {
        let parameters = NWParameters.padBridge()
        // 同じ Mac の補助アプリだけがつなげるようにする
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        guard let listener = try? NWListener(using: parameters) else {
            Self.logger.error("補助アプリとの接続を待ち受けられない")
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
        // 前の Host から残った補助アプリには新しい接続先が渡らないので、いつも新しく起動する。古い方は接続が切れて自分で終わる
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--port", String(port.rawValue), "--token", token]
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    Self.logger.error("補助アプリを起動できない: \(error, privacy: .public)")
                }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = MessageChannel(connection: connection, queue: queue)
        pending[ObjectIdentifier(channel)] = channel
        channel.start(
            onStateChange: { [weak self, weak channel] state in
                switch state {
                case .failed, .cancelled:
                    guard let self, let channel else { return }
                    pending[ObjectIdentifier(channel)] = nil
                    guard channel === self.channel else { return }
                    self.channel = nil
                    finishPendingReady()
                    // 補助アプリが落ちたら、iPad がつながっている間は起動し直す
                    if isRunning {
                        start()
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
                    Self.logger.notice("補助アプリとつながった")
                // 合言葉を確かめた接続からのものだけを受ける
                case let .microphoneRelayReady(isUsingPadMicrophone) where channel === self.channel:
                    finishPendingReady(isUsingPadMicrophone: isUsingPadMicrophone)
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
