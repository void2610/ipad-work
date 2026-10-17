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
    /// 今表示している映像に写っている、Mac の画面の範囲。
    private(set) var videoRegion = VideoRegion.full
    // 送ってほしいと頼んだ範囲。つなぎ直したときに頼み直す
    private var requestedRegion = VideoRegion.full
    /// Mac の Typeless が聞き取っているか。押した直後は求めた状態を先に見せ、Mac から実際の状態が届いたらそれに合わせる。
    private(set) var isVoiceInputActive = false
    /// iPad のマイクを使えないときの知らせ。
    private(set) var microphoneNotice: String?
    /// Mac で鳴っている音を iPad で鳴らすか。鳴らしている間、Mac のスピーカーからは鳴らない。
    /// 裏に回っている間は Mac で鳴らす。iPad をしまったまま Mac を開いたときに、Mac が無音のままにならないように。
    private(set) var playsMacAudio = UserDefaults.standard.bool(forKey: HostSession.playsMacAudioKey)

    /// iPad のマイクで拾っている声の大きさ (0...1)。画面の書き換えごとに読む値なので、変化を SwiftUI には知らせない。
    @ObservationIgnored var microphoneLevel: Float {
        microphone.level
    }

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "session")
    private static let playsMacAudioKey = "playsMacAudio"
    // 映像の受信と復号を操作の通信から切り離し、映像が重くても操作が遅れないようにする
    private let videoQueue = DispatchQueue(label: "dev.void2610.padbridge.pad.video")
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var isClosed = false
    private var isForeground = true
    // iPad から始めさせた聞き取りか。裏に回るときに、Mac で直接始めた聞き取りまで止めないために覚える
    private var isVoiceInputStartedHere = false
    private let microphone = MicrophoneStreamer()
    private var microphoneStopTask: Task<Void, Never>?
    private var retryDelay: Duration = .milliseconds(500)
    private var retryTask: Task<Void, Never>?
    private var videoRetryTask: Task<Void, Never>?
    private(set) var modifierLatch = ModifierLatch()
    private var pointerModifiers = PointerModifierHold()
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
        renderer.onRegionChange = { [weak self] region in
            Task { @MainActor in self?.videoRegion = region }
        }
        BackgroundAudio.shared.start()
        connectControl()
    }

    func send(_ message: ControlMessage) {
        control?.send(.control(message))
    }

    func toggleModifier(_ modifier: KeyModifiers) {
        modifierLatch.tap(modifier, at: ProcessInfo.processInfo.systemUptime)
    }

    /// バーのキーを押す。バーの修飾キーが有効なら一緒に押す。
    func tapKey(usage: Int) {
        RemoteKeys.withModifiers(modifierLatch.active, RemoteKeys.tap(usage: usage)).forEach(send)
        modifierLatch.consume()
    }

    /// ソフトウェアキーボードで打った文字を、そのまま Mac に送る。
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        RemoteKeys.typed(text, modifiers: modifierLatch.active).forEach(send)
        modifierLatch.consume()
    }

    /// 画面のタッチから来たクリックやドラッグに、バーの修飾キーを効かせて送る。
    func sendPointer(_ messages: [ControlMessage]) {
        let wrapped = pointerModifiers.wrap(messages, modifiers: modifierLatch.active)
        wrapped.messages.forEach(send)
        if wrapped.didUseModifiers {
            modifierLatch.consume()
        }
    }

    /// 拡大している間は、見えている範囲だけを Mac の解像度で送ってもらう。
    func requestVideoRegion(_ region: VideoRegion) {
        guard region != requestedRegion else { return }
        requestedRegion = region
        send(.videoRegion(region))
    }

    func setPlaysMacAudio(_ isEnabled: Bool) {
        playsMacAudio = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.playsMacAudioKey)
        updateMacAudio()
    }

    private func updateMacAudio() {
        let isEnabled = playsMacAudio && isForeground
        send(.macAudio(isEnabled: isEnabled))
        if !isEnabled {
            BackgroundAudio.shared.macAudio.reset()
        }
    }

    func swipeDesktop(_ direction: TouchInterpreter.SwipeDirection) {
        send(.desktopSwipe(direction))
    }

    func showDock() {
        RemoteKeys.focusDock().forEach(send)
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
    /// 始めるときは iPad のマイクの音を Mac へ送り始めてから、Typeless を起動する。Mac は蓋を閉じると内蔵マイクが使えないため。
    func setVoiceInput(_ isActive: Bool) {
        guard isVoiceInputActive != isActive else { return }
        isVoiceInputActive = isActive
        isVoiceInputStartedHere = isActive
        if isActive {
            startMicrophone()
        } else {
            send(.voiceInput(isActive: false))
            // Mac が Typeless を止めたら知らせが来て止める。来なかったときのために、少し待ってからも止める
            microphoneStopTask?.cancel()
            microphoneStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.stopMicrophone()
            }
        }
    }

    private func startMicrophone() {
        microphoneStopTask?.cancel()
        microphone.requestPermission { [weak self] permission in
            // 許可を尋ねている間に離された場合は、始めない
            guard let self, isVoiceInputActive, isVoiceInputStartedHere else { return }
            switch permission {
            case .granted:
                microphoneNotice = nil
                if !microphone.isRunning, let channel = control {
                    microphone.start { samples in channel.send(.audio(samples)) }
                    // iPad のスピーカーで鳴らした Mac の音を、マイクから Typeless に入れない
                    BackgroundAudio.shared.macAudio.setSuppressed(microphone.isRunning)
                }
            case .denied:
                microphoneNotice = "iPad のマイクが許可されていないので、Mac のマイクで聞き取ります。設定の「PadBridge」でマイクを許可してください。"
            }
            send(.voiceInput(isActive: true))
        }
    }

    private func stopMicrophone() {
        microphone.stop()
        BackgroundAudio.shared.macAudio.setSuppressed(false)
    }

    func close() {
        commitAppSwitch()
        stopVoiceInputStartedHere()
        stopMicrophone()
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
        if playsMacAudio {
            updateMacAudio()
        }
        if isForeground {
            startVideoIfNeeded()
        } else {
            // 押しっぱなしのまま裏に回ると、Mac の Typeless が聞き取り続けてしまう
            stopVoiceInputStartedHere()
            stopMicrophone()
            commitAppSwitch()
            stopVideo()
        }
    }

    private func stopVoiceInputStartedHere() {
        if isVoiceInputStartedHere {
            setVoiceInput(false)
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
        // 接続が切れた時点で Mac 側は iPad が始めさせた聞き取りを止める。つなぎ直したら Mac から実際の状態が届く
        isVoiceInputActive = false
        isVoiceInputStartedHere = false
        stopMicrophone()
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
        if case let .macAudio(samples) = message {
            BackgroundAudio.shared.macAudio.feed(samples)
            return
        }
        guard case let .control(message) = message else { return }
        switch message {
        case let .welcome(_, status):
            hostStatus = status
            phase = .connected
            // Mac はつながるたびに画面全体から始めるので、拡大していれば頼み直す
            if !requestedRegion.isFull {
                send(.videoRegion(requestedRegion))
            }
            if playsMacAudio, isForeground {
                send(.macAudio(isEnabled: true))
            }
            startVideoIfNeeded()
        case let .hostStatus(status):
            hostStatus = status
        case let .voiceInputState(isActive):
            isVoiceInputActive = isActive
            if !isActive {
                isVoiceInputStartedHere = false
                stopMicrophone()
            }
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
