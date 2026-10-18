import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import os
import PadBridgeKit

/// iPad からの接続を待ち受け、操作の反映と画面の配信を受け持つ。状態は `queue` の上でだけ触る。
nonisolated final class HostServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "server")
    private let queue = DispatchQueue(label: "dev.void2610.padbridge.host.server")
    // 文字入力の AX 呼び出しは相手アプリの応答待ちで止まりうるので、通信とは別の直列キューで順に処理する
    private let inputQueue = DispatchQueue(label: "dev.void2610.padbridge.host.input")
    private let hostName: String
    private let onClientChange: @Sendable (String?) -> Void
    private let onListenerChange: @Sendable (String) -> Void
    private let onStatusChange: @Sendable (HostStatus) -> Void
    private let onMacAudioChange: @Sendable (Bool) -> Void
    private let onShownDisplayChange: @Sendable (String?) -> Void
    private let onVideoStatsChange: @Sendable (VideoStats?) -> Void
    private let injector: InputInjector

    private var listener: NWListener?
    // start から stop までの間か。止めたあとで待ち受けを作り直さない
    private var isServing = false
    private var pending: [ObjectIdentifier: MessageChannel] = [:]
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var streamer: ScreenStreamer?
    // 映像の要求で受け取った、iPad が表示できる最大の大きさ。画面の構成が変わって取り込みを作り直すときにも使う
    private var videoMaxSize = (width: 0, height: 0)
    // 取り込みを始めたときの画面。解像度や置き場所が変わったら、取り込みを作り直す
    private var streamedDisplay: DisplayLayout?
    // 映せる画面と、iPad に映している画面。画面の名前はメインスレッドでしか読めないので、そこで読んだ一覧を持っておく
    private var selection = DisplaySelection()
    // 画面ごとの、メニューバーと Dock を除いた範囲。手前のウィンドウを移す先を決めるのに使う
    private var usableAreas: [UInt32: CGRect] = [:]
    private static let preferredDisplayKey = "preferredDisplayUUID"
    private var screenObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    private var inputModeMonitor: InputModeMonitor?
    // Mac の文字入力が英数とかなのどちらか。iPad の特殊キーの列で効いている方を示すのに送る
    private var inputMode: MacInputMode?
    // アプリが前に出るたびに増やす。続けて切り替えたときに、前のアプリの問い合わせが後から返っても使わない
    private var activationCount = 0
    private var displayChange: DispatchWorkItem?
    // iPad に画面を映している間は、操作せず見ているだけでも Mac の画面が眠って映らなくならないようにする
    private var displayAssertion: IOPMAssertionID?
    // iPad が見ている範囲。映像の接続を張り直しても引き継ぐ
    private var videoRegion = VideoRegion.full
    private var typeless: TypelessMonitor?
    private var microphone: MicrophoneRelay?
    // iPad が頼んでいる間だけ、Mac で鳴っている音を iPad へ送る
    private var macAudio: MacAudioCapture?
    // iPad が頼んだ毎秒の枚数。低電力モードや本体が熱いときに少なく頼まれる
    private var videoFrameRate = PreferredFrameRate.normal
    // 映像を送っている間、iPad の「接続の状態」に映像の状態を送る
    private var statsTimer: DispatchSourceTimer?
    // iPad に知らせた、回線に合わせて画質を下げているか。同じことを何度も知らせない
    private var isVideoQualityReduced = false
    // iPad が求めた Mac の音の形式。求めない古い iPad アプリには無圧縮で送る
    private var macAudioCodec = MacAudio.Codec.pcm
    // 今の聞き取りで、既定の入力を iPad のマイクにしたか
    private var isUsingPadMicrophone = false
    private var microphoneStop: DispatchWorkItem?
    // Typeless は前の聞き取りを文字にして貼り付け終えるまで (止めてから数秒)、ショートカットを受け付けない。その間は押し直す
    private static let voiceInputRetryCount = 4
    private var typelessCannotReadPadMicrophone = false
    private var typelessUsesOtherMicrophone = false
    private var didOpenAudioCaptureSettings = false
    // Typeless のマイクの設定は Typeless を終了させるので、同時に 2 つ走らせない
    private var isSettingUpTypelessMicrophone = false
    // iPad から届いた音声入力の要求。古い要求の続きで Typeless を押したり、その結果を知らせたりしないようにする
    private var voiceInputRequests = VoiceInputRequests()

    init(
        hostName: String,
        doubleClickInterval: TimeInterval,
        keyRepeatDelay: TimeInterval,
        keyRepeatInterval: TimeInterval,
        onClientChange: @escaping @Sendable (String?) -> Void,
        onListenerChange: @escaping @Sendable (String) -> Void,
        onStatusChange: @escaping @Sendable (HostStatus) -> Void,
        onMacAudioChange: @escaping @Sendable (Bool) -> Void,
        onShownDisplayChange: @escaping @Sendable (String?) -> Void,
        onVideoStatsChange: @escaping @Sendable (VideoStats?) -> Void
    ) {
        self.hostName = hostName
        self.onClientChange = onClientChange
        self.onListenerChange = onListenerChange
        self.onStatusChange = onStatusChange
        self.onMacAudioChange = onMacAudioChange
        self.onShownDisplayChange = onShownDisplayChange
        self.onVideoStatsChange = onVideoStatsChange
        injector = InputInjector(queue: inputQueue, doubleClickInterval: doubleClickInterval, keyRepeatDelay: keyRepeatDelay, keyRepeatInterval: keyRepeatInterval)
    }

    func start() {
        queue.async {
            self.isServing = true
            self.startListener()
            self.typeless = TypelessMonitor { [weak self] isRecording in
                guard let self else { return }
                queue.async { self.typelessRecordingChanged(isRecording) }
            }
            // 前の補助アプリが後始末をできずに終わって残ったデバイスを消す。この時点では、この Host の補助アプリはまだ動いていない
            PadMicrophoneDevice.removeLeftovers()
            self.microphone = MicrophoneRelay(queue: self.queue) { [weak self] in
                guard let self else { return }
                publishStatus()
            }
            self.screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async { self.screenParametersChanged() }
            }
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                queue.async { self.applicationActivated(pid) }
            }
            self.refreshDisplays()
            self.startInputModeMonitor()
        }
    }

    /// 入力ソースはメインスレッドで読むので、見張りもメインスレッドで動かす。
    private func startInputModeMonitor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let monitor = MainActor.assumeIsolated {
                let monitor = InputModeMonitor { [weak self] mode in
                    guard let self else { return }
                    queue.async { self.inputModeChanged(mode) }
                }
                monitor.start()
                return monitor
            }
            queue.async { self.inputModeMonitor = monitor }
        }
    }

    private func inputModeChanged(_ mode: MacInputMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        control?.send(.control(.macInputMode(mode)))
    }

    func stop() {
        queue.async {
            self.isServing = false
            self.listener?.cancel()
            self.listener = nil
            self.pending.values.forEach { $0.cancel() }
            self.pending.removeAll()
            self.closeSession()
            self.microphoneStop?.cancel()
            self.microphone?.stop()
            self.displayChange?.cancel()
            if let screenObserver = self.screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
            if let activationObserver = self.activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            if let monitor = self.inputModeMonitor {
                self.inputModeMonitor = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { monitor.stop() } }
            }
        }
    }

    /// 待ち受けが失敗したまま残ると、蓋を閉じた Mac では Host を起動し直すまで iPad からつなげない。少し待って作り直す。
    private func restartListener() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            // 止めたあとで作り直すと、終わるはずの Host が Bonjour の名前を持ち続け、起動し直した Host と取り合う
            guard let self, isServing, listener == nil else { return }
            Self.logger.notice("待ち受けを作り直す")
            startListener()
        }
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .padBridge())
            listener.service = NWListener.Service(name: hostName, type: PadBridgeService.type)
            listener.stateUpdateHandler = { [weak self] state in
                Self.logger.info("listener: \(String(describing: state), privacy: .public)")
                switch state {
                case .ready: self?.onListenerChange("待機中")
                case let .failed(error):
                    self?.onListenerChange("待ち受けに失敗: \(error.localizedDescription)")
                    self?.restartListener()
                case let .waiting(error): self?.onListenerChange("待機準備中: \(error.localizedDescription)")
                default: break
                }
            }
            listener.serviceRegistrationUpdateHandler = { change in
                Self.logger.info("bonjour: \(String(describing: change), privacy: .public)")
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Self.logger.error("listener の作成に失敗: \(error, privacy: .public)")
            onListenerChange("待ち受けに失敗: \(error.localizedDescription)")
            restartListener()
        }
    }

    /// Mac で直接 Typeless を使ったときや、Typeless が自分で聞き取りを終えたときも、iPad のボタンの表示を合わせる。
    private func typelessRecordingChanged(_ isRecording: Bool) {
        Self.logger.notice("Typeless の聞き取り: \(isRecording ? "開始" : "終了", privacy: .public)")
        inputQueue.async { [injector] in injector.typelessRecordingChanged(isRecording) }
        // 止めた直後に iPad でまた始めたとき、前の聞き取りの終わりで新しい聞き取りの準備を消さない。始まらなければ押し直しのあとで知らせる
        if !isRecording, !voiceInputRequests.announcesStop { return }
        control?.send(.control(.voiceInputState(isActive: isRecording)))
        if isRecording, isUsingPadMicrophone {
            checkTypelessAudioCaptureRefusal()
            checkTypelessMicrophone()
        }
        if !isRecording {
            microphone?.endListening()
            // 別のマイクで聞き取った知らせは、その聞き取りの間だけ出す。Typeless で選ばれたマイクを変えないときに、画面に出続けないように
            if typelessUsesOtherMicrophone {
                typelessUsesOtherMicrophone = false
                publishStatus()
            }
        }
    }

    /// Typeless が「PadBridge iPad マイク」を読めたかを、macOS の許可の記録から見分ける。
    /// 読めないとき Typeless は無音のまま聞き取りを続けるので、聞き取りの状態からは分からない。
    /// Typeless は録音の理由の説明を持たないので、許可を加えていないと tccd が「Refusing ... kTCCServiceAudioCapture ... now.typeless.desktop」を記録する。
    /// アプリから他のアプリの許可を前もって読む方法はない (TCCAccessPreflightWithAuditToken は権限のない呼び出し元には正しい値を返さない)。
    private func checkTypelessAudioCaptureRefusal() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show", "--last", "5s", "--style", "compact", "--predicate",
                #"process == "tccd" AND eventMessage CONTAINS "Refusing" AND eventMessage CONTAINS "kTCCServiceAudioCapture" AND eventMessage CONTAINS "now.typeless.desktop""#,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let refused = output.contains("Refusing")
            guard let self else { return }
            queue.async {
                Self.logger.notice("Typeless のシステムオーディオの録音: \(refused ? "拒否された" : "拒否の記録なし", privacy: .public)")
                self.setTypelessCannotReadPadMicrophone(refused)
            }
        }
    }

    /// Typeless が「PadBridge iPad マイク」で録音しているかを確かめる。このデバイスは Mac の既定の入力になれないので、
    /// Typeless の「自動検出」のままだと内蔵マイク (蓋を閉じていると無音) で録音してしまう。
    private func checkTypelessMicrophone() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, TypelessMonitor.isRecording() else { return }
            let devices = TypelessMonitor.inputDeviceUIDs()
            Self.logger.notice("Typeless が録音しているマイク: \(devices.joined(separator: ", "), privacy: .public)")
            // タップの集約デバイスで録音しているときは、プロセスのデバイスの一覧が空になる。分からないときは知らせない
            guard !devices.isEmpty else { return }
            let usesPadMicrophone = devices.contains(PadMicrophoneDevice.uid)
            guard typelessUsesOtherMicrophone == usesPadMicrophone else { return }
            typelessUsesOtherMicrophone = !usesPadMicrophone
            publishStatus()
            if !usesPadMicrophone {
                setUpTypelessMicrophone(after: 0)
            }
        }
    }

    /// Typeless が聞き取っていない間に、Typeless のマイクを「PadBridge iPad マイク」にする (自動検出のときだけ。Typeless を起動し直す)。
    private func setUpTypelessMicrophone(after delay: TimeInterval) {
        guard !isSettingUpTypelessMicrophone else { return }
        isSettingUpTypelessMicrophone = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            // 聞き取りの途中や、止めたあとで文字にして貼り付けている間 (数秒かかる) に Typeless を終了させない。8 秒続けて聞き取っていないときだけ進める
            var quietSince: TimeInterval?
            var isQuiet = false
            for _ in 0 ..< 600 {
                let now = ProcessInfo.processInfo.systemUptime
                if TypelessMonitor.isRecording() {
                    quietSince = nil
                } else if quietSince == nil {
                    quietSince = now
                }
                if let quietSince, now - quietSince >= 8 {
                    isQuiet = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let result = isQuiet
                ? TypelessMicrophoneSetup.selectPadMicrophone(deviceName: PadMicrophoneDevice.name)
                : .skipped("Typeless が 2 分のあいだ聞き取りを続けていたので、終了させない")
            guard let self else { return }
            queue.async {
                self.isSettingUpTypelessMicrophone = false
                switch result {
                case .configured, .alreadySelected:
                    if self.typelessUsesOtherMicrophone {
                        self.typelessUsesOtherMicrophone = false
                        self.publishStatus()
                    }
                case let .skipped(reason):
                    Self.logger.notice("Typeless のマイクの設定をしない: \(reason, privacy: .public)")
                }
            }
        }
    }

    private func setTypelessCannotReadPadMicrophone(_ value: Bool) {
        guard typelessCannotReadPadMicrophone != value else { return }
        typelessCannotReadPadMicrophone = value
        publishStatus()
        guard value, !didOpenAudioCaptureSettings else { return }
        // Typeless に許可を足す画面を Mac で開いておき、iPad に映った画面で「＋」を押すだけにする。接続ごとに 1 回だけ
        didOpenAudioCaptureSettings = true
        Self.logger.notice("Typeless が iPad のマイクを読めないので、画面とシステムオーディオの録音の設定を開く")
        DispatchQueue.main.async {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = MessageChannel(connection: connection, queue: queue)
        let id = ObjectIdentifier(channel)
        pending[id] = channel
        // つないだまま名乗らない相手を、いつまでも残さない
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel, pending[id] === channel else { return }
            pending[id] = nil
            channel.cancel()
        }
        channel.start(
            onStateChange: { [weak self, weak channel] state in
                switch state {
                case .failed, .cancelled:
                    guard let self, let channel else { return }
                    queue.async { self.channelClosed(channel) }
                default:
                    break
                }
            },
            onMessage: { [weak self, weak channel] message in
                guard let self, let channel else { return }
                handle(message, from: channel)
            }
        )
    }

    private func handle(_ message: WireMessage, from channel: MessageChannel) {
        if case let .audio(samples) = message {
            if channel === control {
                microphone?.feed(samples)
            }
            return
        }
        guard case let .control(message) = message else { return }
        if case let .hello(role, deviceName, maxWidth, maxHeight) = message {
            pending[ObjectIdentifier(channel)] = nil
            switch role {
            case .control: beginSession(on: channel, deviceName: deviceName)
            case .video: beginVideo(on: channel, maxWidth: maxWidth, maxHeight: maxHeight)
            }
            return
        }
        if case let .videoFrameReceived(presentationTimeMicros) = message {
            if channel === video {
                streamer?.frameReceived(presentationTimeMicros: presentationTimeMicros)
            }
            return
        }
        guard channel === control else { return }
        switch message {
        case .requestKeyFrame:
            streamer?.requestKeyFrame()
        case let .videoRegion(region):
            videoRegion = region
            streamer?.setRegion(region)
        case let .insertText(text):
            // 入力内容そのものはログに残さない
            Self.logger.info("文字入力を受信: \(text.count) 文字")
            inputQueue.async { TextInserter.insert(text) }
        case let .voiceInput(isActive):
            Self.logger.notice("Typeless の音声入力: \(isActive ? "開始" : "完了", privacy: .public)")
            let requestCount = voiceInputRequests.receive(isActive: isActive)
            if isActive {
                // Typeless が録音を始める前に、iPad の声を流す準備をしておく
                microphone?.beginListening { [weak self, inputQueue, injector] isUsingPadMicrophone in
                    // 補助アプリの返事を待つ間に iPad で止めた (または切れた) ときは、もう始めない
                    guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
                    self.isUsingPadMicrophone = isUsingPadMicrophone
                    inputQueue.async {
                        injector.handle(message)
                        // Typeless を起動して待ち受けるのを待ったときも、押したときから数える
                        self.queue.async { self.confirmVoiceInputStarted(message, requestCount: requestCount, retriesLeft: Self.voiceInputRetryCount) }
                    }
                }
            } else if isUsingPadMicrophone, let microphone {
                // 止めたところまでの声を Typeless に聞かせ終えてから止め、話し終わりを切らない
                microphone.finishListening { [weak self] in
                    guard let self else { return }
                    queue.async { self.stopTypeless(message, requestCount: requestCount) }
                }
            } else {
                stopTypeless(message, requestCount: requestCount)
            }
        case let .videoFrameRate(rate):
            setVideoFrameRate(rate)
        case let .macAudioCodec(codec):
            macAudioCodec = codec
        case let .macAudio(isEnabled):
            Self.logger.notice("Mac の音を iPad で鳴らす: \(isEnabled ? "始める" : "やめる", privacy: .public)")
            setMacAudio(isEnabled, on: channel)
        case let .selectDisplay(id):
            selectDisplay(id)
        case let .moveFrontWindow(id):
            moveFrontWindow(to: id)
        case .showDock:
            showDock()
        case .releaseHeldInput:
            inputQueue.async { [injector] in injector.releaseHeldInput() }
        case let .desktopSwipe(direction):
            Self.logger.info("3 本指スワイプ: \(direction.rawValue, privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .mouseMove, .mouseButton, .scroll, .key:
            Self.logger.debug("操作を受信: \(String(describing: message), privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .hello, .welcome, .hostStatus, .voiceInputState, .displays, .macInputMode, .acknowledgeVideoFrames, .videoFrameReceived, .videoQuality, .videoStats, .microphoneRelayHello, .microphoneRelay, .microphoneRelayReady, .microphoneRelayStatus, .microphoneRelayFinish, .microphoneRelayFinished:
            break
        }
    }

    private func setMacAudio(_ isEnabled: Bool, on channel: MessageChannel) {
        if isEnabled, macAudio == nil {
            // 塊は取り込みのキューから順に届くので、符号化もその上で順に行う
            let encoder = macAudioCodec == .opus ? MacAudioEncoder() : nil
            Self.logger.notice("Mac の音の形式: \(encoder == nil ? "無圧縮" : "Opus", privacy: .public)")
            let capture = MacAudioCapture { [weak channel] samples in
                // 届かずにたまっている間は捨て、つながり直したときにまとめて鳴って遅れないようにする
                guard let channel, channel.pendingSendCount < 25 else { return }
                if let encoder {
                    encoder.encode(samples).forEach { channel.send(.macAudioOpus($0)) }
                } else {
                    channel.send(.macAudio(samples))
                }
            }
            capture.start()
            macAudio = capture
            onMacAudioChange(true)
        } else if !isEnabled {
            stopMacAudio()
        }
    }

    private func stopMacAudio() {
        guard let macAudio else { return }
        macAudio.stop()
        self.macAudio = nil
        onMacAudioChange(false)
    }

    /// 完了のショートカットを押す。その間に iPad でまた始めていたら、Typeless は聞き取りを続けるので押さない。
    private func stopTypeless(_ message: ControlMessage, requestCount: Int) {
        guard voiceInputRequests.isCurrent(requestCount) else { return }
        inputQueue.async { [injector] in injector.handle(message) }
        // Typeless がショートカットに反応しなかったときは状態の変化が来ないので、待ってから実際の状態を知らせて iPad の表示を戻す
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            control?.send(.control(.voiceInputState(isActive: TypelessMonitor.isRecording())))
        }
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime + 0.5) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            microphone?.endListening()
        }
    }

    /// iPad から始めたのに Typeless が聞き取りを始めないときは、押し直す。その間も iPad の声は補助アプリがためておくので、遅れて始まっても話し始めは落ちない。
    /// 押し直しても始まらなければ、iPad の表示を戻す。iPad に「止まった」と知らせると iPad はマイクを止めるので、あきらめるまでは知らせない。
    private func confirmVoiceInputStarted(_ message: ControlMessage, requestCount: Int, retriesLeft: Int) {
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            if TypelessMonitor.isRecording() {
                voiceInputRequests.settle(requestCount)
                control?.send(.control(.voiceInputState(isActive: true)))
            } else if retriesLeft > 0 {
                Self.logger.notice("Typeless が聞き取りを始めないので、ショートカットを押し直す (残り \(retriesLeft) 回)")
                inputQueue.async { [injector] in injector.handle(message) }
                confirmVoiceInputStarted(message, requestCount: requestCount, retriesLeft: retriesLeft - 1)
            } else {
                Self.logger.notice("Typeless が聞き取りを始めなかった")
                voiceInputRequests.settle(requestCount)
                control?.send(.control(.voiceInputState(isActive: false)))
                microphone?.endListening()
            }
        }
    }

    private func beginSession(on channel: MessageChannel, deviceName: String) {
        // 新しい iPad が来たら古いセッションは捨てる。同時に操作されると入力が混ざるため
        closeSession()
        control = channel
        videoFrameRate = PreferredFrameRate.normal
        macAudioCodec = .pcm
        isVideoQualityReduced = false
        // つなぎ直しの原因を後から追えるよう、どの経路 (Wi-Fi のネットワークか、Wi-Fi の直接通信 awdl か) かも記録する
        let interface = channel.connection.currentPath?.availableInterfaces.first?.name ?? "不明"
        Self.logger.notice("接続: \(deviceName, privacy: .public) (\(interface, privacy: .public))")
        didOpenAudioCaptureSettings = false
        // 前の iPad が拡大していた範囲を引き継がない。拡大していれば iPad が頼み直す
        videoRegion = .full
        typeless?.start()
        microphoneStop?.cancel()
        microphoneStop = nil
        microphone?.start()
        // 補助アプリがデバイスを作り、Typeless がそれをマイクの一覧に載せてから、Typeless に使わせる設定をする
        setUpTypelessMicrophone(after: 5)
        channel.send(.control(.welcome(hostName: hostName, status: currentStatus())))
        channel.send(.control(.voiceInputState(isActive: TypelessMonitor.isRecording())))
        sendDisplays()
        if let inputMode {
            channel.send(.control(.macInputMode(inputMode)))
        }
        onClientChange(deviceName)
    }

    private func beginVideo(on channel: MessageChannel, maxWidth: Int, maxHeight: Int) {
        guard control != nil else {
            channel.cancel()
            return
        }
        stopVideo()
        video = channel
        videoMaxSize = (maxWidth, maxHeight)
        // 受け取りの返事で、回線に入りきらないフレームを送らずに捨てる
        channel.send(.control(.acknowledgeVideoFrames))
        // 新しい映像の接続では、ビットレートを上限から測り直すので、画質を下げた知らせも初めからにする
        isVideoQualityReduced = false
        let status = currentStatus()
        Self.logger.info("映像の要求: \(maxWidth)x\(maxHeight)、画面収録=\(status.canCaptureScreen)、アクセシビリティ=\(status.canControlInput)")
        control?.send(.control(.hostStatus(status)))
        guard status.canCaptureScreen else { return }
        // 眠っている画面は取り込めないことがあるので、始める前に起こす。始められずに張り直しが続くときは、iPad が張り直す間隔を延ばしていく
        keepDisplayAwake(true)
        startStreamer(on: channel)
        startStatsTimer()
    }

    private func startStreamer(on channel: MessageChannel) {
        // 画面を替えて作り直しても回線は同じなので、返事を返す iPad かと、下げたビットレートを引き継ぐ。測り直す間に遅い回線で遅れがたまらないように
        let previous = streamer.flatMap { $0.channel === channel ? $0 : nil }
        streamer?.stop()
        let displayID = selection.shownID ?? CGMainDisplayID()
        let streamer = ScreenStreamer(
            channel: channel, displayID: displayID, maxWidth: videoMaxSize.width, maxHeight: videoMaxSize.height, region: videoRegion,
            isAcknowledged: previous?.isAcknowledged ?? false, initialBitRate: previous?.currentBitRate, initialRoundTrip: previous?.currentRoundTrip,
            frameRate: videoFrameRate,
            onQualityChange: { [weak self] isReduced in
                self?.queue.async { self?.videoQualityChanged(isReduced) }
            }
        )
        self.streamer = streamer
        streamedDisplay = DisplayLayout(of: displayID)
        Task {
            do {
                try await streamer.start()
            } catch {
                Self.logger.error("画面の取り込みを開始できない: \(error, privacy: .public)")
                let isDisplayMissing = (error as? ScreenStreamerError) == .displayNotFound
                self.queue.async {
                    guard self.streamer === streamer else { return }
                    // ScreenCaptureKit の一覧にない画面 (CoreGraphics には見えていても取り込めないもの) で黒いまま繰り返さないよう、メインディスプレイを映す
                    if isDisplayMissing, let video = self.video, self.selection.fallBackToMain() {
                        self.applyShownDisplay()
                        self.sendDisplays()
                        self.startStreamer(on: video)
                    } else {
                        self.stopVideo()
                    }
                }
            }
        }
    }

    private func setVideoFrameRate(_ requested: Int) {
        let rate = min(max(requested, PreferredFrameRate.range.lowerBound), PreferredFrameRate.range.upperBound)
        guard rate != videoFrameRate else { return }
        videoFrameRate = rate
        Self.logger.notice("iPad の頼みで、映像を毎秒 \(rate) 枚までにする")
        // 取り込みの間隔とエンコーダの想定は作るときに決まるので、作り直す
        if let video, streamer != nil {
            startStreamer(on: video)
        }
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, let stats = streamer?.stats else { return }
            control?.send(.control(.videoStats(stats)))
            onVideoStatsChange(stats)
        }
        timer.resume()
        statsTimer = timer
    }

    private func videoQualityChanged(_ isReduced: Bool) {
        guard isReduced != isVideoQualityReduced else { return }
        isVideoQualityReduced = isReduced
        Self.logger.notice("回線に合わせて画質を\(isReduced ? "下げた" : "戻した", privacy: .public)と iPad に知らせる")
        control?.send(.control(.videoQuality(isReduced: isReduced)))
    }

    private func channelClosed(_ channel: MessageChannel) {
        pending[ObjectIdentifier(channel)] = nil
        if channel === control {
            closeSession()
        } else if channel === video {
            stopVideo()
        }
    }

    private func screenParametersChanged() {
        displayChange?.cancel()
        // 1 回の変更で続けて届くことがあるので、落ち着いてから 1 度だけ読み直す
        let change = DispatchWorkItem { [weak self] in self?.refreshDisplays() }
        displayChange = change
        queue.asyncAfter(deadline: .now() + 0.5, execute: change)
    }

    /// 画面の名前は NSScreen からしか読めないので、メインスレッドで読んでから受け取る。
    private func refreshDisplays() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = MainActor.assumeIsolated { DisplayCatalog.current() }
            queue.async { self.displaysChanged(snapshot) }
        }
    }

    /// 選ばれた画面が外れたらメインディスプレイを映し、つなぎ直されたらまた選ばれた画面を映す。
    /// 取り込みは始めたときの画面の大きさのまま続き、触った位置とずれるので、映す画面やその解像度・置き場所が変わったら作り直す。
    private func displaysChanged(_ snapshot: DisplayCatalog.Snapshot) {
        usableAreas = snapshot.usableAreas
        let update = selection.update(snapshot.displays, preferred: preferredDisplayID())
        if update.isShownChanged {
            applyShownDisplay()
        }
        if update.needsAnnouncement {
            Self.logger.notice("映せる画面: \(snapshot.displays.map(\.label).joined(separator: "、"), privacy: .public)")
            sendDisplays()
        }
        guard let video, streamer != nil, let shownID = selection.shownID, streamedDisplay != DisplayLayout(of: shownID) else { return }
        Self.logger.notice("Mac の画面の構成が変わったので、取り込みを作り直す")
        startStreamer(on: video)
    }

    private func selectDisplay(_ id: CGDirectDisplayID) {
        switchDisplay(to: id, reason: "映す画面を選んだ", movesPointer: true)
    }

    /// 手前のウィンドウを選ばれた画面へ移し、その画面を映す。画面をまたいでドラッグできない代わり。
    private func moveFrontWindow(to id: CGDirectDisplayID) {
        guard selection.contains(id) else {
            sendDisplays()
            return
        }
        let usableAreas = usableAreas
        // アクセシビリティの操作は相手のアプリの応答を待つので、サーバーのキューの外で行う
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isMoved = DisplayCatalog.moveFrontWindow(to: id, usableAreas: usableAreas)
            guard let self else { return }
            queue.async {
                Self.logger.notice("手前のウィンドウを画面 \(id) へ: \(isMoved ? "移した" : "移せない", privacy: .public)")
                guard isMoved else { return }
                self.switchDisplay(to: id, reason: "手前のウィンドウを移した画面を映す", movesPointer: true)
            }
        }
    }

    /// Dock を出してキーボードで選べるようにする。映していない画面に出ると iPad では見えないまま Dock に入力が移るので、先に Dock のある画面を映す。
    private func showDock() {
        if selection.hasMultipleDisplays, let id = DisplayCatalog.dockDisplay(), id != selection.shownID {
            switchDisplay(to: id, reason: "Dock のある画面を映す", movesPointer: false)
        }
        inputQueue.async { [injector] in
            RemoteKeys.focusDock().forEach(injector.handle)
        }
    }

    /// 前に出たアプリのウィンドウが別の画面にあれば、その画面を映す。iPad のアプリ切替で選んだアプリが、映していない画面にあって見えないままにならないように。
    private func applicationActivated(_ pid: pid_t) {
        activationCount += 1
        let count = activationCount
        guard video != nil, selection.hasMultipleDisplays, pid != ProcessInfo.processInfo.processIdentifier else { return }
        // 前に出てからウィンドウが手前に来るまで少しかかる。アクセシビリティの問い合わせは相手の応答を待つので、サーバーのキューの外で行う
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let frame = DisplayCatalog.focusedWindowFrame(of: pid), let self else { return }
            queue.async {
                guard count == self.activationCount else { return }
                self.followWindow(at: frame)
            }
        }
    }

    private func followWindow(at frame: CGRect) {
        let bounds = Dictionary(uniqueKeysWithValues: selection.displays.map { ($0.id, CGDisplayBounds($0.id)) })
        guard let id = RemoteDisplay.showing(window: frame, displays: bounds), id != selection.shownID else { return }
        // Mac を直接使っている人のマウスを奪わないよう、ポインタは動かさない
        switchDisplay(to: id, reason: "前に出たウィンドウのある画面を映す", movesPointer: false)
    }

    /// 画面を覚えて映す。外したあとでつなぎ直しても、その画面を映す。
    private func switchDisplay(to id: CGDirectDisplayID, reason: String, movesPointer: Bool) {
        let result = selection.switchTo(id)
        guard result != .missing, let display = selection.displays.first(where: { $0.id == id }) else {
            sendDisplays()
            return
        }
        Self.logger.notice("\(reason, privacy: .public): \(display.label, privacy: .public)")
        if let uuid = DisplayCatalog.uuid(of: id) {
            UserDefaults.standard.set(uuid, forKey: Self.preferredDisplayKey)
        }
        guard result == .switched else { return }
        applyShownDisplay()
        if movesPointer {
            inputQueue.async { [injector] in injector.moveToDisplayCenter() }
        }
        sendDisplays()
        if let video, streamer != nil {
            startStreamer(on: video)
        }
    }

    /// 映す画面が替わったときに、拡大の範囲とタッチを届ける画面を合わせる。
    private func applyShownDisplay() {
        // 前の画面で拡大していた範囲は、別の画面では意味がない。iPad も画面が替わると拡大を戻す
        videoRegion = .full
        let displayID = selection.shownID
        inputQueue.async { [injector] in injector.setDisplay(displayID) }
    }

    private func sendDisplays() {
        // Mac の前にいる人にも、iPad がどの画面を見ているかを Host のメニューで見せる (画面が 2 台以上のときだけ)
        let shown = selection.displays.first { $0.id == selection.shownID }
        onShownDisplayChange(control != nil && selection.hasMultipleDisplays ? shown?.label : nil)
        guard let announcement = selection.announcement else { return }
        control?.send(.control(announcement))
    }

    private func preferredDisplayID() -> CGDirectDisplayID? {
        UserDefaults.standard.string(forKey: Self.preferredDisplayKey).flatMap(DisplayCatalog.id(ofUUID:))
    }

    private func stopVideo() {
        statsTimer?.cancel()
        statsTimer = nil
        onVideoStatsChange(nil)
        keepDisplayAwake(false)
        streamer?.stop()
        streamer = nil
        streamedDisplay = nil
        video?.cancel()
        video = nil
    }

    private func closeSession() {
        stopVideo()
        guard let control else { return }
        Self.logger.notice("切断")
        control.cancel()
        self.control = nil
        // 押し直しや補助アプリの返事を待っている要求が、切れたあとで Typeless を始めないようにする
        voiceInputRequests.cancelAll()
        onShownDisplayChange(nil)
        typeless?.stop()
        stopMacAudio()
        microphone?.endListening()
        // つなぎ直すたびに補助アプリを起動し直すと、デバイスを作り直して点検し終えるまで iPad のマイクを使えない。しばらく残しておく
        scheduleMicrophoneStop(after: 60)
        inputQueue.async { [injector] in injector.releaseAll() }
        onClientChange(nil)
    }

    private func keepDisplayAwake(_ isAwake: Bool) {
        if isAwake, displayAssertion == nil {
            // 眠らせないアサーションは、もう眠っている画面を起こさない。映し始めるときに操作があったと知らせて起こす
            var activity = IOPMAssertionID(0)
            if IOPMAssertionDeclareUserActivity("iPad に画面を映し始めた" as CFString, kIOPMUserActiveLocal, &activity) == kIOReturnSuccess {
                IOPMAssertionRelease(activity)
            }
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "iPad に画面を映している" as CFString, &id) == kIOReturnSuccess {
                displayAssertion = id
            }
        } else if !isAwake, let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
    }

    /// 補助アプリを止める。Mac で直接 Typeless を使っている最中は、デバイスが消えて録音が途切れないよう、終わるまで待つ。
    private func scheduleMicrophoneStop(after delay: TimeInterval) {
        let stopMicrophone = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if TypelessMonitor.isRecording() {
                scheduleMicrophoneStop(after: 5)
            } else {
                microphone?.stop()
            }
        }
        microphoneStop = stopMicrophone
        queue.asyncAfter(deadline: .now() + delay, execute: stopMicrophone)
    }

    /// 状態を iPad と Mac のメニューの両方に知らせる。
    private func publishStatus() {
        let status = currentStatus()
        control?.send(.control(.hostStatus(status)))
        onStatusChange(status)
    }

    private func currentStatus() -> HostStatus {
        HostStatus(
            canCaptureScreen: CGPreflightScreenCaptureAccess(),
            canControlInput: AXIsProcessTrusted(),
            canRelayMicrophone: !(microphone?.isKnownUnauthorized ?? false),
            typelessCannotReadPadMicrophone: typelessCannotReadPadMicrophone,
            typelessUsesOtherMicrophone: typelessUsesOtherMicrophone
        )
    }
}
