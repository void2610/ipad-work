import Foundation
import Network
import Observation
import os
import PadBridgeKit
import UIKit

/// 1 台の Mac との接続。操作用と映像用の 2 本の接続を持ち、切断されたら自分で再接続する。
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
                // 再接続のたびに数え直すと、再接続の間隔 (最大 5 秒) より長く待てないので、接続が切れたときから数える
                watchReachability()
            }
        }
    }
    /// 接続を試みてしばらくたっても接続できない。「接続中…」が続くだけで理由が分からないので、確認すべきことを通知する。
    private(set) var isUnreachable = false
    private var reachabilityTask: Task<Void, Never>?
    private(set) var hostStatus: HostStatus?
    private(set) var videoSize = CGSize.zero
    /// 映像を表示しているか。映像の接続を再確立している間は、前のサイズが残っていても表示していない。
    private(set) var isVideoShown = false
    /// Mac が 2 秒ごとに送る映像の状態と、その間に iPad に届いた映像のフレーム数とデータ量。「接続の状態」に表示する。
    private(set) var videoStats: VideoStats?
    private(set) var receivedRate: (framesPerSecond: Double, megabitsPerSecond: Double)?
    /// Mac との接続経路 (Wi-Fi ネットワークか、Wi-Fi ダイレクトか)。状態が届くたびに読み直す。
    private(set) var route: String?
    private let receiveMeter = ReceiveRateMeter()
    // Mac に要求したフレームレート (fps)。Mac は接続のたびに 60 から始める
    private var requestedFrameRate = PreferredFrameRate.normal
    private var powerObservers: [any NSObjectProtocol] = []
    /// 現在表示している映像に写っている、Mac のディスプレイの範囲。
    private(set) var videoRegion = VideoRegion.full
    // 送信を要求した範囲。再接続したときに要求し直す
    private var requestedRegion = VideoRegion.full
    /// Mac の Typeless が音声入力中か。押した直後は要求した状態を先に表示し、Mac から実際の状態が届いたらそれに合わせる。
    private(set) var isVoiceInputActive = false
    /// iPad のマイクを使えないときの通知。
    private(set) var microphoneNotice: String?
    /// Mac で再生中のオーディオを iPad で再生するか。再生している間、Mac のスピーカーからは出ない。
    /// バックグラウンドに移っている間は Mac で再生する。iPad をしまったまま Mac を開いたときに、Mac が無音のままにならないように。
    private(set) var playsMacAudio = UserDefaults.standard.bool(forKey: HostSession.playsMacAudioKey)
    /// Mac に接続中の、表示可能なディスプレイ。2 台以上あれば、表示するディスプレイを選べる。
    private(set) var displays: [RemoteDisplay] = []
    /// 現在表示している Mac のディスプレイ。
    private(set) var shownDisplayID: UInt32?
    /// Mac の文字入力が英数とかなのどちらか。古い Host からは届かないので nil のままになる。
    private(set) var macInputMode: MacInputMode?
    /// Mac の画面がロックされているか。ロック中は映像が止まり、入力も届かないことがあるので、黒いままの理由を表示する。
    private(set) var isMacScreenLocked = false
    /// Mac の Host のビルドが、この iPad アプリと異なるときの Mac 側のコミット。片方だけ古いと、古い側の挙動を見て取り違える。
    private(set) var mismatchedHostCommit: String?
    /// Mac の Host のビルド元コミット。「接続の状態」に表示する。古い Host からは届かない。
    private(set) var hostCommit: String?
    /// 表示するディスプレイが切り替わったときや、回線に合わせて画質を変えたときに、短時間だけ表示する通知。Mac が自分で切り替えたときも、何が起きたか分かるように。
    /// 種類ごとに保持し、ディスプレイ切り替えの通知で画質低下の通知が消えないようにする。
    private(set) var notices: [TransientNotice] = []
    private var noticeTasks: [TransientNotice.Kind: Task<Void, Never>] = [:]

    /// iPad のマイクで拾っている音量 (0...1)。画面の再描画ごとに読む値なので、変化を SwiftUI には通知しない。
    @ObservationIgnored var microphoneLevel: Float {
        microphone.level
    }

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "session")
    private static let playsMacAudioKey = "playsMacAudio"
    // 映像の受信とデコードを操作の通信から切り離し、映像が重くても操作が遅れないようにする
    private let videoQueue = DispatchQueue(label: "dev.void2610.padbridge.pad.video")
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var isClosed = false
    private var isForeground = true
    // iPad から開始した音声入力か。バックグラウンドに移るときに、Mac で直接開始した音声入力まで止めないために保持する
    private var isVoiceInputStartedHere = false
    private let microphone = MicrophoneStreamer()
    private var microphoneStopTask: Task<Void, Never>?
    private var retryDelay: Duration = .milliseconds(500)
    private var retryTask: Task<Void, Never>?
    private var videoRetryTask: Task<Void, Never>?
    // 映像の再接続の間隔。Mac がキャプチャを開始できないときに、0.5 秒おきに再接続し続けないよう延ばしていく
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
        // 低電力モードや本体の発熱状態が変わったら、受信したい映像のフレームレートを要求し直す
        powerObservers = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestFrameRateIfChanged() }
            }
        }
        renderer.onNeedsKeyFrame = { [weak self] in
            Task { @MainActor in self?.send(.requestKeyFrame) }
        }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in
                self?.videoSize = size
                self?.isVideoShown = true
                // 映像が届いたので、再接続の間隔を戻す
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

    /// バーの修飾キーの状態を使わず、渡した修飾キーで押す。リピート時に使う。
    func tapKey(usage: Int, modifiers: KeyModifiers) {
        RemoteKeys.withModifiers(modifiers, RemoteKeys.tap(usage: usage)).forEach(send)
    }

    /// ソフトウェアキーボードで入力した文字を、そのまま Mac に送る。
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        RemoteKeys.typed(text, modifiers: modifierLatch.active).forEach(send)
        modifierLatch.consume()
    }

    /// 画面のタッチによるクリックやドラッグに、バーの修飾キーを適用して送る。
    func sendPointer(_ messages: [ControlMessage]) {
        let wrapped = pointerModifiers.wrap(messages, modifiers: modifierLatch.active)
        wrapped.messages.forEach(send)
        if wrapped.didUseModifiers {
            modifierLatch.consume()
        }
    }

    /// 拡大中は、表示範囲だけを Mac の解像度で送ってもらう。
    func requestVideoRegion(_ region: VideoRegion) {
        guard region != requestedRegion else { return }
        requestedRegion = region
        send(.videoRegion(region))
    }

    func selectDisplay(_ id: UInt32) {
        // 再接続中は Mac に届かないので、表示だけ先に切り替えない
        guard phase == .connected, id != shownDisplayID else { return }
        showDisplay(id)
        send(.selectDisplay(id: id))
    }

    /// 最前面のウィンドウをこのディスプレイへ移す。移せたら Mac がそのディスプレイを表示する。
    func moveFrontWindow(to id: UInt32) {
        guard phase == .connected else { return }
        send(.moveFrontWindow(toDisplay: id))
    }

    private func showDisplay(_ id: UInt32) {
        guard id != shownDisplayID else { return }
        let isSwitching = shownDisplayID != nil
        shownDisplayID = id
        guard isSwitching else { return }
        // 前のディスプレイで拡大していた範囲は、別のディスプレイでは意味がない。切り替え前に要求した範囲が後から届いても、全体に戻させる
        requestedRegion = .full
        send(.videoRegion(.full))
        announceDisplay(id)
    }

    private func announceDisplay(_ id: UInt32) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        showNotice(TransientNotice(kind: .display, text: "\(display.label) を表示中", systemImage: "display"))
    }

    private func showNotice(_ notice: TransientNotice, for duration: Duration = .seconds(2)) {
        if let index = notices.firstIndex(where: { $0.kind == notice.kind }) {
            notices[index] = notice
        } else {
            notices.append(notice)
        }
        noticeTasks[notice.kind]?.cancel()
        noticeTasks[notice.kind] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notices.removeAll { $0.kind == notice.kind }
        }
    }

    /// 低電力モードのときや本体が高温のときは、フレームレートを半分にしてもらい、デコードと描画の電力消費と発熱を抑える。
    private func requestFrameRateIfChanged() {
        let rate = PreferredFrameRate.choose(
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState, current: requestedFrameRate
        )
        guard rate != requestedFrameRate, phase == .connected else { return }
        requestedFrameRate = rate
        send(.videoFrameRate(rate))
    }

    /// 映像を止めたら、前の映像の状態を表示したままにしない。
    private func clearVideoStats() {
        videoStats = nil
        receivedRate = nil
        route = nil
        receiveMeter.reset()
    }

    private func clearNotices() {
        noticeTasks.values.forEach { $0.cancel() }
        noticeTasks = [:]
        notices = []
    }

    func setPlaysMacAudio(_ isEnabled: Bool) {
        playsMacAudio = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.playsMacAudioKey)
        updateMacAudio()
    }

    private func updateMacAudio() {
        let isEnabled = playsMacAudio && isForeground
        if isEnabled {
            sendMacAudioCodec()
        }
        send(.macAudio(isEnabled: isEnabled))
        if !isEnabled {
            BackgroundAudio.shared.macAudio.reset()
        }
    }

    /// Mac のオーディオを Opus で送ってもらう。無圧縮だと約 1.5 Mbps になり、遅い回線では映像の帯域を圧迫する。
    private func sendMacAudioCodec() {
        send(.macAudioCodec(BackgroundAudio.shared.macAudio.canDecodeOpus ? .opus : .pcm))
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

    /// Mac の Typeless で音声入力を開始する (true) か、終了する (false)。
    /// 開始時は iPad のマイク音声を Mac へ送り始めてから、Typeless を起動する。Mac は蓋を閉じると内蔵マイクが使えないため。
    func setVoiceInput(_ isActive: Bool) {
        guard isVoiceInputActive != isActive else { return }
        isVoiceInputActive = isActive
        isVoiceInputStartedHere = isActive
        if isActive {
            startMicrophone()
        } else {
            send(.voiceInput(isActive: false))
            // Mac が Typeless を停止したら通知が来て停止する。来なかったときのために、少し待ってからも停止する
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
            // 権限を確認している間に離された場合は、開始しない
            guard let self, isVoiceInputActive, isVoiceInputStartedHere else { return }
            switch permission {
            case .granted:
                microphoneNotice = nil
                if !microphone.isRunning, let channel = control {
                    microphone.start { samples in channel.send(.audio(samples)) }
                    // iPad のスピーカーで再生した Mac のオーディオを、マイクから Typeless に入れない
                    BackgroundAudio.shared.macAudio.setSuppressed(microphone.isRunning)
                    if !microphone.isRunning {
                        // 電話のあとや、ほかのアプリがマイクを使っているときは開始できない。黙って Mac の無音を音声入力させない
                        microphoneNotice = "iPad のマイクを開始できなかったため、Mac のマイクで音声入力します。"
                    }
                }
            case .denied:
                microphoneNotice = "iPad のマイクへのアクセスが許可されていないため、Mac のマイクで音声入力します。設定の「PadBridge」でマイクを許可してください。"
            }
            send(.voiceInput(isActive: true))
        }
    }

    private func stopMicrophone() {
        microphone.stop()
        BackgroundAudio.shared.macAudio.setSuppressed(false)
    }

    func close() {
        powerObservers.forEach(NotificationCenter.default.removeObserver)
        powerObservers = []
        commitAppSwitch()
        stopVoiceInputStartedHere()
        stopMicrophone()
        isClosed = true
        retryTask?.cancel()
        videoRetryTask?.cancel()
        // 次に接続したセッションのマイクや「届かない」の表示に、前のセッションの予約が影響しないように
        microphoneStopTask?.cancel()
        reachabilityTask?.cancel()
        replaceControl(with: nil)
        stopVideo()
        clearNotices()
        // 次に接続したときに、前の接続で溜まった Mac のオーディオが再生されないように
        BackgroundAudio.shared.macAudio.reset()
        BackgroundAudio.shared.stop()
    }

    /// バックグラウンドに移っている間は操作用の接続だけ保ち、映像は止めてバッテリーと通信量を抑える。
    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        if playsMacAudio {
            updateMacAudio()
        }
        if isForeground {
            // バックグラウンドにいる間に無音の再生が止まっていたら再生し直す。止まったままだと、次にバックグラウンドに移ったときに iPadOS に停止されて接続が切れる
            BackgroundAudio.shared.resumeIfNeeded()
            startVideoIfNeeded()
        } else {
            // iPadOS に奪われて離した通知が届かなかったキーやボタンを、Mac に押したまま残さない
            send(.releaseHeldInput)
            // 押しっぱなしのままバックグラウンドに移ると、Mac の Typeless が音声入力し続けてしまう
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
            onMessage: { [weak self, weak channel] message in
                MainActor.assumeIsolated {
                    // 再接続したあとに、前の接続から遅れて届いたものを接続済みとして扱わない
                    guard let self, let channel, channel === self.control else { return }
                    self.handleControl(message)
                }
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
        // 接続が切れた時点で Mac 側は iPad が開始した音声入力を停止する。再接続したら Mac から実際の状態が届く
        isVoiceInputActive = false
        isVoiceInputStartedHere = false
        // 再接続するまで Mac の文字入力の状態は分からない。再接続すると Mac から届く
        macInputMode = nil
        // 切断時に Mac は押したままのものを解除するので、iPad も修飾キーを押したままの扱いで残さない
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
        switch message {
        case let .macAudio(samples):
            // 切断後 (バックグラウンドに移ったあと) も、送信途中のオーディオが少し届く。再生すると停止したはずの音が再び出るので破棄する
            if playsMacAudio, isForeground {
                BackgroundAudio.shared.macAudio.feed(samples)
            }
            return
        case let .macAudioOpus(packet):
            if playsMacAudio, isForeground {
                BackgroundAudio.shared.macAudio.feedOpus(packet)
            }
            return
        default:
            break
        }
        guard case let .control(message) = message else { return }
        switch message {
        case let .welcome(_, status):
            // ロックされていれば、続けて Mac が通知する
            isMacScreenLocked = false
            if let commit = BuildCommit.current() {
                send(.buildCommit(commit))
            }
            // 接続しただけでは戻さない。接続直後に Mac に切断されることが続くときに、0.5 秒おきに再接続し続けないように
            retryDelay = .milliseconds(500)
            hostStatus = status
            phase = .connected
            // Mac は接続のたびにディスプレイ全体から始めるので、拡大していれば要求し直す
            if !requestedRegion.isFull {
                send(.videoRegion(requestedRegion))
            }
            if playsMacAudio, isForeground {
                sendMacAudioCodec()
                send(.macAudio(isEnabled: true))
            }
            requestedFrameRate = PreferredFrameRate.normal
            requestFrameRateIfChanged()
            startVideoIfNeeded()
        case let .hostStatus(status):
            hostStatus = status
        case let .displays(displays, shownID):
            self.displays = displays
            showDisplay(shownID)
        case let .macInputMode(mode):
            macInputMode = mode
        case let .macScreenLocked(isLocked):
            isMacScreenLocked = isLocked
        case let .buildCommit(hostCommit):
            self.hostCommit = hostCommit
            mismatchedHostCommit = BuildCommit.isMismatch(BuildCommit.current(), hostCommit) ? hostCommit : nil
        case let .videoStats(stats):
            // 映像を止めた直後に届いた分で、止める前の状態を再表示しない
            guard video != nil else { break }
            videoStats = stats
            receivedRate = receiveMeter.take(at: ProcessInfo.processInfo.systemUptime)
            route = control?.connection.currentPath?.availableInterfaces.first.map { ConnectionRoute.label(interfaceName: $0.name, type: $0.type) }
        case let .videoQuality(isReduced):
            // 映像がぼやけたり元に戻ったりした理由が分かるように
            let notice = isReduced
                ? TransientNotice(kind: .quality, text: "回線が遅いため、画質を下げています", systemImage: "wifi.exclamationmark")
                : TransientNotice(kind: .quality, text: "画質を戻しました", systemImage: "wifi")
            showNotice(notice, for: .seconds(3))
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
        isVideoShown = false
        videoQueue.async { renderer.reset() }
        let channel = MessageChannel(connection: NWConnection(to: host.endpoint, using: .padBridge()), queue: videoQueue)
        video = channel
        let size = Self.maxVideoSize()
        let acknowledger = VideoAcknowledger()
        let receiveMeter = receiveMeter
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
                // 描画前に応答を返し、描画時間で Mac の送信を待たせない
                if let reply = acknowledger.reply(to: message) {
                    channel?.send(reply)
                }
                if case let .videoFrame(frame) = message {
                    receiveMeter.record(bytes: frame.data.count, at: ProcessInfo.processInfo.systemUptime)
                }
                renderer.handle(message)
            }
        )
    }

    private func stopVideo() {
        let old = video
        video = nil
        isVideoShown = false
        clearVideoStats()
        old?.cancel()
    }

    private func videoLost() {
        video = nil
        isVideoShown = false
        clearVideoStats()
        let delay = videoRetryDelay
        videoRetryDelay = min(videoRetryDelay * 2, .seconds(5))
        videoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startVideoIfNeeded()
        }
    }

    /// 横向きにしたときのディスプレイの画素数。Mac はこれに収まるサイズでディスプレイをキャプチャする。
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

/// ディスプレイ上に短時間だけ表示する通知。
struct TransientNotice: Equatable, Identifiable {
    enum Kind {
        case display
        case quality
    }

    var kind: Kind
    var text: String
    var systemImage: String

    var id: Kind {
        kind
    }
}
