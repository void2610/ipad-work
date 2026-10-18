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
    private(set) var phase = Phase.connecting {
        didSet {
            if phase == .connected {
                reachabilityTask?.cancel()
                reachabilityTask = nil
                isUnreachable = false
            } else if oldValue == .connected {
                // つなぎ直すたびに数え直すと、つなぎ直す間隔 (最大 5 秒) より長く待てないので、つながりが切れたときから数える
                watchReachability()
            }
        }
    }
    /// つなごうとしてしばらくたってもつながらない。「接続中…」が続くだけで理由が分からないので、確かめることを知らせる。
    private(set) var isUnreachable = false
    private var reachabilityTask: Task<Void, Never>?
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
    /// Mac につながっている、映せる画面。2 台以上あれば、映す画面を選べる。
    private(set) var displays: [RemoteDisplay] = []
    /// 今映している Mac の画面。
    private(set) var shownDisplayID: UInt32?
    /// Mac の文字入力が英数とかなのどちらか。古い Host からは届かないので nil のままになる。
    private(set) var macInputMode: MacInputMode?
    /// 映す画面が替わったときに、少しの間だけ出す知らせ。前に出たウィンドウを追って Mac が替えたときも、何が起きたか分かるように。
    private(set) var displayNotice: String?
    private var displayNoticeTask: Task<Void, Never>?

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
    // 映像の接続を張り直す間隔。Mac が取り込みを始められないときに、0.5 秒おきに張り直し続けないよう延ばしていく
    private var videoRetryDelay: Duration = .milliseconds(500)
    private(set) var modifierLatch = ModifierLatch()
    private var pointerModifiers = PointerModifierHold()
    private var appSwitcher = AppSwitcher()
    private var appSwitchCommit: Task<Void, Never>?

    init(host: DiscoveredHost) {
        self.host = host
    }

    private func watchReachability() {
        reachabilityTask?.cancel()
        reachabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, phase != .connected else { return }
            isUnreachable = true
        }
    }

    func start() {
        watchReachability()
        renderer.onNeedsKeyFrame = { [weak self] in
            Task { @MainActor in self?.send(.requestKeyFrame) }
        }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in
                self?.videoSize = size
                // 映像が届いたので、張り直す間隔を戻す
                self?.videoRetryDelay = .milliseconds(500)
            }
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
        tapKey(usage: usage, modifiers: modifierLatch.active)
        modifierLatch.consume()
    }

    /// バーの修飾キーの状態を使わず、渡した修飾キーで押す。押し続けて繰り返すときに使う。
    func tapKey(usage: Int, modifiers: KeyModifiers) {
        RemoteKeys.withModifiers(modifiers, RemoteKeys.tap(usage: usage)).forEach(send)
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

    func selectDisplay(_ id: UInt32) {
        // つなぎ直している間は Mac に届かないので、表示だけ先に替えない
        guard phase == .connected, id != shownDisplayID else { return }
        showDisplay(id)
        send(.selectDisplay(id: id))
    }

    /// 手前のウィンドウをこの画面へ移す。移せたら Mac がその画面を映す。
    func moveFrontWindow(to id: UInt32) {
        guard phase == .connected else { return }
        send(.moveFrontWindow(toDisplay: id))
    }

    private func showDisplay(_ id: UInt32) {
        guard id != shownDisplayID else { return }
        let isSwitching = shownDisplayID != nil
        shownDisplayID = id
        guard isSwitching else { return }
        // 前の画面で拡大していた範囲は、別の画面では意味がない。画面を替える前に頼んだ範囲が後から届いても、全体に戻させる
        requestedRegion = .full
        send(.videoRegion(.full))
        announceDisplay(id)
    }

    private func announceDisplay(_ id: UInt32) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        displayNotice = "\(display.label) を映しています"
        displayNoticeTask?.cancel()
        displayNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.displayNotice = nil
        }
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

    /// iPadOS が先に受け取って Mac に届かないショートカットを、「…」から送る。
    func sendShortcut(usage: Int, modifiers: KeyModifiers) {
        RemoteKeys.withModifiers(modifiers, RemoteKeys.tap(usage: usage)).forEach(send)
    }

    func showDock() {
        send(.showDock)
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
            // iPadOS に取られて離した知らせが届かなかったキーやボタンを、Mac に押したまま残さない
            send(.releaseHeldInput)
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
        // つなぎ直すまで Mac の文字入力の状態は分からない。つなぎ直すと Mac から届く
        macInputMode = nil
        // 切れたときに Mac は押したままのものを離すので、iPad も修飾キーを押したつもりのまま残さない
        pointerModifiers = PointerModifierHold()
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
            // 切ったあと (裏に回ったあと) も、送られている途中の音が少し届く。鳴らすと止めたはずの音がまた鳴るので捨てる
            if playsMacAudio, isForeground {
                BackgroundAudio.shared.macAudio.feed(samples)
            }
            return
        }
        guard case let .control(message) = message else { return }
        switch message {
        case let .welcome(_, status):
            // つながっただけでは戻さない。つながってすぐ Mac に切られることが続くときに、0.5 秒おきにつなぎ直し続けないように
            retryDelay = .milliseconds(500)
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
        case let .displays(displays, shownID):
            self.displays = displays
            showDisplay(shownID)
        case let .macInputMode(mode):
            macInputMode = mode
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
        let acknowledger = VideoAcknowledger()
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
            onMessage: { [weak channel] message in
                // 描く前に返し、描く時間で Mac が送るのを待たせない
                if let reply = acknowledger.reply(to: message) {
                    channel?.send(reply)
                }
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
        let delay = videoRetryDelay
        videoRetryDelay = min(videoRetryDelay * 2, .seconds(5))
        videoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
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
