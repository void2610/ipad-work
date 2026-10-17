import Foundation
import Network
import Observation
import os
import PadBridgeKit
import UIKit

/// 1 台の Mac との接続。操作用と映像用の 2 本の接続を持ち、切れたら自分でつなぎ直す。
@Observable
final class HostSession {
    enum Phase {
        case connecting
        case connected
        case reconnecting
    }

    let host: DiscoveredHost
    let renderer = VideoRenderer()
    private(set) var phase = Phase.connecting
    private(set) var hostStatus: HostStatus?
    private(set) var videoSize = CGSize.zero
    private(set) var isVoiceInputActive = false

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "session")
    // 映像の受信と復号を操作の通信から切り離し、映像が重くても操作が遅れないようにする
    private let videoQueue = DispatchQueue(label: "dev.void2610.padbridge.pad.video")
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var isClosed = false
    private var isForeground = true
    private var retryDelay: Duration = .milliseconds(500)
    private var retryTask: Task<Void, Never>?
    private var videoRetryTask: Task<Void, Never>?
    private var appSwitcher = AppSwitcher()
    private var appSwitchCommit: Task<Void, Never>?

    init(host: DiscoveredHost) {
        self.host = host
    }

    func start() {
        renderer.onNeedsKeyFrame = { [weak self] in
            Task { @MainActor in self?.send(.requestKeyFrame) }
        }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in self?.videoSize = size }
        }
        BackgroundAudio.shared.start()
        connectControl()
    }

    func send(_ message: ControlMessage) {
        control?.send(.control(message))
    }

    func tapKey(usage: Int, modifiers: KeyModifiers = []) {
        RemoteKeys.tap(usage: usage, modifiers: modifiers).forEach(send)
    }

    func swipeDesktop(_ direction: TouchInterpreter.SwipeDirection) {
        send(.desktopSwipe(direction))
    }

    /// Command+Tab のアプリ切り替え。タップのたびに次のアプリへ進み、1 秒タップがなければ確定する。
    func switchApp() {
        appSwitcher.tap(at: ProcessInfo.processInfo.systemUptime).forEach(send)
        appSwitchCommit?.cancel()
        appSwitchCommit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppSwitcher.commitDelay))
            guard let self, !Task.isCancelled else { return }
            appSwitcher.commitIfDue(at: ProcessInfo.processInfo.systemUptime).forEach(send)
        }
    }

    private func commitAppSwitch() {
        appSwitchCommit?.cancel()
        appSwitchCommit = nil
        appSwitcher.commit().forEach(send)
    }

    /// Mac の Typeless で音声入力を始める (true) か、終える (false)。
    func setVoiceInput(_ isActive: Bool) {
        guard isVoiceInputActive != isActive else { return }
        isVoiceInputActive = isActive
        send(.voiceInput(isActive: isActive))
    }

    func close() {
        commitAppSwitch()
        setVoiceInput(false)
        isClosed = true
        retryTask?.cancel()
        videoRetryTask?.cancel()
        replaceControl(with: nil)
        stopVideo()
        BackgroundAudio.shared.stop()
    }

    /// 裏に回っている間は操作用の接続だけ保ち、映像は止めて電池と通信量を抑える。
    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        if isForeground {
            startVideoIfNeeded()
        } else {
            // 押しっぱなしのまま裏に回ると、Mac の Typeless が聞き取り続けてしまう
            setVoiceInput(false)
            commitAppSwitch()
            stopVideo()
        }
    }

    // MARK: - 操作用の接続

    private func connectControl() {
        let channel = MessageChannel(connection: NWConnection(to: host.endpoint, using: .padBridge()), queue: .main)
        replaceControl(with: channel)
        channel.start(
            onStateChange: { [weak self, weak channel] state in
                MainActor.assumeIsolated {
                    guard let self, let channel, channel === self.control else { return }
                    self.controlStateChanged(state)
                }
            },
            onMessage: { [weak self] message in
                MainActor.assumeIsolated { self?.handleControl(message) }
            }
        )
    }

    private func replaceControl(with channel: MessageChannel?) {
        let old = control
        control = channel
        old?.cancel()
    }

    private func controlStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            retryDelay = .milliseconds(500)
            send(.hello(role: .control, deviceName: UIDevice.current.name, maxVideoWidth: 0, maxVideoHeight: 0))
        case let .waiting(error), let .failed(error):
            Self.logger.info("接続できない: \(error, privacy: .public)")
            connectionLost()
        case .cancelled:
            connectionLost()
        default:
            break
        }
    }

    private func connectionLost() {
        guard !isClosed, retryTask == nil else { return }
        // 接続が切れた時点で Mac 側は押していたキーを離すので、こちらの表示も合わせる
        isVoiceInputActive = false
        replaceControl(with: nil)
        stopVideo()
        phase = .reconnecting
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(5))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            connectControl()
        }
    }

    private func handleControl(_ message: WireMessage) {
        guard case let .control(message) = message else { return }
        switch message {
        case let .welcome(_, status):
            hostStatus = status
            phase = .connected
            startVideoIfNeeded()
        case let .hostStatus(status):
            hostStatus = status
        default:
            break
        }
    }

    // MARK: - 映像用の接続

    private func startVideoIfNeeded() {
        guard phase == .connected, isForeground, video == nil, !isClosed else { return }
        videoRetryTask?.cancel()
        let renderer = renderer
        videoQueue.async { renderer.reset() }
        let channel = MessageChannel(connection: NWConnection(to: host.endpoint, using: .padBridge()), queue: videoQueue)
        video = channel
        let size = Self.maxVideoSize()
        channel.start(
            onStateChange: { [weak self, weak channel] state in
                switch state {
                case .ready:
                    channel?.send(.control(.hello(role: .video, deviceName: "", maxVideoWidth: size.width, maxVideoHeight: size.height)))
                case .failed, .cancelled:
                    Task { @MainActor in
                        guard let self, let channel, channel === self.video else { return }
                        self.videoLost()
                    }
                default:
                    break
                }
            },
            onMessage: { message in
                renderer.handle(message)
            }
        )
    }

    private func stopVideo() {
        let old = video
        video = nil
        old?.cancel()
    }

    private func videoLost() {
        video = nil
        videoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.startVideoIfNeeded()
        }
    }

    /// 横向きにしたときの画面の画素数。Mac はこれに収まる大きさで画面を取り込む。
    private static func maxVideoSize() -> (width: Int, height: Int) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let bounds = screen?.nativeBounds ?? CGRect(x: 0, y: 0, width: 2048, height: 2732)
        return (Int(max(bounds.width, bounds.height)), Int(min(bounds.width, bounds.height)))
    }
}

enum HIDUsage {
    static let returnKey = 0x28
    static let escape = 0x29
    static let backspace = 0x2A
    static let tab = 0x2B
}
