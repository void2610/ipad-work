import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import os
import PadBridgeKit

/// iPad からの接続を待ち受け、操作の反映とディスプレイの配信を担う。状態は `queue` 上でのみ操作する。
nonisolated final class HostServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "server")
    private let queue = DispatchQueue(label: "dev.void2610.padbridge.host.server")
    // 文字入力の AX 呼び出しは相手アプリの応答待ちでブロックしうるので、通信とは別のシリアルキューで順に処理する
    private let inputQueue = DispatchQueue(label: "dev.void2610.padbridge.host.input")
    private let hostName: String
    private let onClientChange: @Sendable (String?) -> Void
    private let onListenerChange: @Sendable (String) -> Void
    private let onStatusChange: @Sendable (HostStatus) -> Void
    private let onMacAudioChange: @Sendable (Bool) -> Void
    private let onShownDisplayChange: @Sendable (String?) -> Void
    private let onVideoStatsChange: @Sendable (VideoStats?) -> Void
    private let onBuildMismatch: @Sendable (_ padCommit: String?) -> Void
    private let injector: InputInjector

    private var listener: NWListener?
    // start から stop までの間か。停止後にリスナーを再作成しない
    private var isServing = false
    private var pending: [ObjectIdentifier: MessageChannel] = [:]
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var streamer: ScreenStreamer?
    // 映像リクエストで受け取った、iPad が表示できる最大サイズ。ディスプレイ構成の変更でキャプチャを作り直すときにも使う
    private var videoMaxSize = (width: 0, height: 0)
    // キャプチャ開始時のディスプレイ。解像度や配置が変わったら、キャプチャを作り直す
    private var streamedDisplay: DisplayLayout?
    // 表示可能なディスプレイと、iPad に表示中のディスプレイ。名前はメインスレッドでしか取得できないので、そこで取得した一覧を保持しておく
    private var selection = DisplaySelection()
    // ディスプレイごとの、メニューバーと Dock を除いた範囲。最前面のウィンドウの移動先の決定に使う
    private var usableAreas: [UInt32: CGRect] = [:]
    private static let preferredDisplayKey = "preferredDisplayUUID"
    private var screenObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    private var inputModeMonitor: InputModeMonitor?
    // Mac の文字入力が英数とかなのどちらか。iPad のキーボード上部のバーで有効な方を示すために送る
    private var inputMode: MacInputMode?
    // アプリが最前面に出るたびに増やす。続けて切り替えたときに、前のアプリへの問い合わせ結果が後から返っても使わない
    private var activationCount = 0
    // ScreenCaptureKit の一覧にまだ載らないディスプレイからメインへフォールバックしたあと、選択されたディスプレイに戻れるかを再確認した回数
    private var missingDisplayRetries = 0
    private var displayChange: DispatchWorkItem?
    // iPad にディスプレイを表示している間は、操作せず見ているだけでも Mac がスリープして表示が途切れないようにする
    private var displayAssertion: IOPMAssertionID?
    // iPad が表示している範囲。映像の接続を張り直しても引き継ぐ
    private var videoRegion = VideoRegion.full
    private var typeless: TypelessMonitor?
    private var microphone: MicrophoneRelay?
    // iPad がリクエストしている間だけ、Mac で再生中のサウンドを iPad へ送る
    private var macAudio: MacAudioCapture?
    private var screenLockMonitor: ScreenLockMonitor?
    private var isScreenLocked = false
    // iPad がリクエストした毎秒のフレーム数。低電力モードや本体が高温のときは少なくリクエストされる
    private var videoFrameRate = PreferredFrameRate.normal
    // 映像を送信している間、iPad の「接続の状態」に映像の状態を送る
    private var statsTimer: DispatchSourceTimer?
    // iPad に通知済みの、回線に合わせて画質を下げているか。同じ内容を繰り返し通知しない
    private var isVideoQualityReduced = false
    // iPad がリクエストした Mac のサウンドの形式。リクエストしない古い iPad アプリには非圧縮で送る
    private var macAudioCodec = MacAudio.Codec.pcm
    // 現在の音声入力で、既定の入力を iPad のマイクにしたか
    private var isUsingPadMicrophone = false
    // iPad から開始した音声入力リクエストの番号。ヘルパーアプリの応答が遅れて届いたときに、その音声入力がまだ継続中かを判定する
    private var listeningRequest: Int?
    private var microphoneStop: DispatchWorkItem?
    // Typeless は前の音声入力をテキスト化して貼り付け終えるまで (停止から数秒)、ショートカットを受け付けない。その間は押し直す
    private static let voiceInputRetryCount = 4
    private var typelessCannotReadPadMicrophone = false
    private var typelessUsesOtherMicrophone = false
    private var didOpenAudioCaptureSettings = false
    // Typeless のマイク設定は Typeless を終了させるので、同時に 2 つ実行しない
    private var isSettingUpTypelessMicrophone = false
    // iPad から届いた音声入力のリクエスト。古いリクエストの続きで Typeless を操作したり、その結果を通知したりしないようにする
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
        onVideoStatsChange: @escaping @Sendable (VideoStats?) -> Void,
        onBuildMismatch: @escaping @Sendable (_ padCommit: String?) -> Void
    ) {
        self.hostName = hostName
        self.onClientChange = onClientChange
        self.onListenerChange = onListenerChange
        self.onStatusChange = onStatusChange
        self.onMacAudioChange = onMacAudioChange
        self.onShownDisplayChange = onShownDisplayChange
        self.onVideoStatsChange = onVideoStatsChange
        self.onBuildMismatch = onBuildMismatch
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
            // 前のヘルパーアプリが後始末できずに終了して残ったデバイスを削除する。この時点では、この Host のヘルパーアプリはまだ動いていない
            PadMicrophoneDevice.removeLeftovers()
            self.microphone = MicrophoneRelay(
                queue: self.queue,
                onAuthorizationChange: { [weak self] in self?.publishStatus() },
                onLateReady: { [weak self] isUsingPadMicrophone in self?.microphoneReadyLate(isUsingPadMicrophone) }
            )
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
            self.startScreenLockMonitor()
        }
    }

    /// 入力ソースはメインスレッドで取得するので、監視もメインスレッドで動かす。
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

    /// ディスプレイのロック通知はメインスレッドで受ける。
    private func startScreenLockMonitor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (monitor, isLocked) = MainActor.assumeIsolated {
                let monitor = ScreenLockMonitor { [weak self] isLocked in
                    guard let self else { return }
                    queue.async { self.screenLockChanged(isLocked) }
                }
                monitor.start()
                return (monitor, ScreenLockMonitor.isLocked)
            }
            queue.async {
                self.screenLockMonitor = monitor
                self.isScreenLocked = isLocked
            }
        }
    }

    private func screenLockChanged(_ isLocked: Bool) {
        guard isLocked != isScreenLocked else { return }
        isScreenLocked = isLocked
        Self.logger.notice("Mac のディスプレイ: \(isLocked ? "ロックされた" : "ロックが解除された", privacy: .public)")
        control?.send(.control(.macScreenLocked(isLocked)))
        // ロック中に停止したキャプチャは、解除しても自動では復帰しないので作り直す
        if !isLocked, let video, streamer != nil {
            startStreamer(on: video)
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
            if let monitor = self.screenLockMonitor {
                self.screenLockMonitor = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { monitor.stop() } }
            }
        }
    }

    /// リスナーが失敗したまま残ると、蓋を閉じた Mac では Host を再起動するまで iPad から接続できない。少し待って作り直す。
    private func restartListener() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            // 停止後に作り直すと、終了するはずの Host が Bonjour の名前を保持し続け、再起動した Host と競合する
            guard let self, isServing, listener == nil else { return }
            Self.logger.notice("リスナーを作り直す")
            startListener()
        }
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .padBridge())
            listener.service = NWListener.Service(name: hostName, type: PadBridgeService.type)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Self.logger.info("listener: \(String(describing: state), privacy: .public)")
                // 作り直す前のリスナーから遅れて届いた通知で、新しいリスナーを停止しない
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready: onListenerChange("待機中")
                case let .failed(error):
                    onListenerChange("接続の待ち受けに失敗しました: \(error.localizedDescription)")
                    restartListener()
                case let .waiting(error): onListenerChange("待ち受けの準備中: \(error.localizedDescription)")
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
            onListenerChange("接続の待ち受けに失敗しました: \(error.localizedDescription)")
            restartListener()
        }
    }

    /// Mac で直接 Typeless を使ったときや、Typeless が自分で音声入力を終えたときも、iPad のボタンの表示を合わせる。
    private func typelessRecordingChanged(_ isRecording: Bool) {
        Self.logger.notice("Typeless の音声入力: \(isRecording ? "開始" : "終了", privacy: .public)")
        inputQueue.async { [injector] in injector.typelessRecordingChanged(isRecording) }
        // 停止直後に iPad で再び開始したとき、前の音声入力の終了で新しい音声入力の準備を消さない。開始されなければ押し直したあとで通知する
        if !isRecording, !voiceInputRequests.announcesStop { return }
        control?.send(.control(.voiceInputState(isActive: isRecording)))
        if isRecording, isUsingPadMicrophone {
            checkTypelessAudioCaptureRefusal()
            checkTypelessMicrophone()
        }
        if !isRecording {
            microphone?.endListening()
            // 別のマイクでの音声入力の通知は、その音声入力の間だけ表示する。Typeless で選択されたマイクを変えないときに、表示が出続けないように
            if typelessUsesOtherMicrophone {
                typelessUsesOtherMicrophone = false
                publishStatus()
            }
        }
    }

    /// Typeless が「PadBridge iPad マイク」を読み取れたかを、macOS の許可の記録から判定する。
    /// 読み取れないとき Typeless は無音のまま音声入力を続けるので、音声入力の状態からは判別できない。
    /// Typeless は録音の理由の説明を持たないので、許可を追加していないと tccd が「Refusing ... kTCCServiceAudioCapture ... now.typeless.desktop」を記録する。
    /// アプリが他のアプリの許可を事前に取得する方法はない (TCCAccessPreflightWithAuditToken は権限のない呼び出し元には正しい値を返さない)。
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
                Self.logger.notice("Typeless のシステムオーディオ録音: \(refused ? "拒否された" : "拒否の記録なし", privacy: .public)")
                self.setTypelessCannotReadPadMicrophone(refused)
            }
        }
    }

    /// Typeless が「PadBridge iPad マイク」で録音しているかを確認する。このデバイスは Mac の既定の入力になれないので、
    /// Typeless の「自動検出」のままだと内蔵マイク (蓋を閉じていると無音) で録音してしまう。
    private func checkTypelessMicrophone() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, TypelessMonitor.isRecording() else { return }
            let devices = TypelessMonitor.inputDeviceUIDs()
            Self.logger.notice("Typeless が録音しているマイク: \(devices.joined(separator: ", "), privacy: .public)")
            // タップの機器セットで録音しているときは、プロセスのデバイス一覧が空になる。判別できないときは通知しない
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

    /// Typeless が音声入力中でない間に、Typeless のマイクを「PadBridge iPad マイク」にする (自動検出のときだけ。Typeless を再起動する)。
    private func setUpTypelessMicrophone(after delay: TimeInterval) {
        guard !isSettingUpTypelessMicrophone else { return }
        isSettingUpTypelessMicrophone = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            // 音声入力中や、停止後にテキスト化して貼り付けている間 (数秒かかる) に Typeless を終了させない。8 秒続けて音声入力がないときだけ進める
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
                : .skipped("Typeless が 2 分間音声入力を続けているので、終了させない")
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
                    Self.logger.notice("Typeless のマイクを設定しない: \(reason, privacy: .public)")
                }
            }
        }
    }

    /// ヘルパーアプリの応答がタイムアウト後に届いた。Typeless はすでに「PadBridge iPad マイク」で音声入力を始めているので、停止するときは話し終わりが流れ終わるのを待つ。
    private func microphoneReadyLate(_ isUsingPadMicrophone: Bool) {
        guard isUsingPadMicrophone, let listeningRequest, voiceInputRequests.isCurrent(listeningRequest) else { return }
        Self.logger.notice("ヘルパーアプリの応答が遅れて届いた。iPad の音声を流している状態として扱う")
        self.isUsingPadMicrophone = true
    }

    private func setTypelessCannotReadPadMicrophone(_ value: Bool) {
        guard typelessCannotReadPadMicrophone != value else { return }
        typelessCannotReadPadMicrophone = value
        publishStatus()
        guard value, !didOpenAudioCaptureSettings else { return }
        // Typeless に許可を追加する画面を Mac で開いておき、iPad に表示された画面で「＋」を押すだけにする。接続ごとに 1 回だけ
        didOpenAudioCaptureSettings = true
        Self.logger.notice("Typeless が iPad のマイクを読み取れないので、画面収録とシステムオーディオ録音の設定を開く")
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
        // 接続したまま名乗らない相手を、いつまでも残さない
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
            listeningRequest = isActive ? requestCount : nil
            if isActive {
                // Typeless が録音を始める前に、iPad の音声を流す準備をしておく
                microphone?.beginListening { [weak self, inputQueue, injector] isUsingPadMicrophone in
                    // ヘルパーアプリの応答を待つ間に iPad で停止した (または切断した) ときは、もう開始しない
                    guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
                    self.isUsingPadMicrophone = isUsingPadMicrophone
                    inputQueue.async {
                        injector.handle(message)
                        // Typeless を起動して待機状態になるのを待ったときも、押した時点から数える
                        self.queue.async { self.confirmVoiceInputStarted(message, requestCount: requestCount, retriesLeft: Self.voiceInputRetryCount) }
                    }
                }
            } else if isUsingPadMicrophone, let microphone {
                // 停止した時点までの音声を Typeless に聞かせ終えてから停止し、話し終わりを切らない
                microphone.finishListening { [weak self] in
                    guard let self else { return }
                    queue.async { self.stopTypeless(message, requestCount: requestCount) }
                }
            } else {
                stopTypeless(message, requestCount: requestCount)
            }
        case let .videoFrameRate(rate):
            setVideoFrameRate(rate)
        case let .buildCommit(padCommit):
            let isMismatch = BuildCommit.isMismatch(BuildCommit.current(), padCommit)
            if isMismatch {
                Self.logger.notice("iPad アプリのビルドが異なる: iPad \(padCommit, privacy: .public)")
            }
            onBuildMismatch(isMismatch ? padCommit : nil)
        case let .macAudioCodec(codec):
            macAudioCodec = codec
        case let .macAudio(isEnabled):
            Self.logger.notice("Mac のサウンドを iPad で再生する: \(isEnabled ? "開始" : "停止", privacy: .public)")
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
        case .mouseMove, .mouseButton, .scroll:
            Self.logger.debug("操作を受信: \(String(describing: message), privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .key:
            // 押したキーは記録に残さない (パスワードも入力するため)
            inputQueue.async { [injector] in injector.handle(message) }
        case .hello, .welcome, .hostStatus, .voiceInputState, .displays, .macInputMode, .acknowledgeVideoFrames, .videoFrameReceived, .videoQuality, .videoStats, .macScreenLocked, .microphoneRelayHello, .microphoneRelay, .microphoneRelayReady, .microphoneRelayStatus, .microphoneRelayFinish, .microphoneRelayFinished:
            break
        }
    }

    private func setMacAudio(_ isEnabled: Bool, on channel: MessageChannel) {
        if isEnabled, macAudio == nil {
            // チャンクはキャプチャのキューから順に届くので、エンコードもその上で順に行う
            let encoder = macAudioCodec == .opus ? MacAudioEncoder() : nil
            Self.logger.notice("Mac のサウンドの形式: \(encoder == nil ? "非圧縮" : "Opus", privacy: .public)")
            let capture = MacAudioCapture(send: { [weak channel] samples in
                // 未送信のまま滞留している間は破棄し、再接続したときにまとめて再生されて遅延しないようにする
                guard let channel, channel.pendingSendCount < 25 else { return }
                if let encoder {
                    encoder.encode(samples).forEach { channel.send(.macAudioOpus($0)) }
                } else {
                    channel.send(.macAudio(samples))
                }
            }, onGiveUp: { [weak self] in
                guard let self else { return }
                queue.async { self.stopMacAudio() }
            })
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

    /// 完了のショートカットを押す。その間に iPad で再び開始していたら、Typeless は音声入力を続けるので押さない。
    private func stopTypeless(_ message: ControlMessage, requestCount: Int) {
        guard voiceInputRequests.isCurrent(requestCount) else { return }
        inputQueue.async { [injector] in injector.handle(message) }
        // Typeless がショートカットに反応しなかったときは状態の変化が通知されないので、待ってから実際の状態を通知して iPad の表示を戻す
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            control?.send(.control(.voiceInputState(isActive: TypelessMonitor.isRecording())))
        }
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime + 0.5) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            microphone?.endListening()
        }
    }

    /// iPad から開始したのに Typeless が音声入力を始めないときは、押し直す。その間も iPad の音声はヘルパーアプリがバッファするので、開始が遅れても話し始めは欠けない。
    /// 押し直しても始まらなければ、iPad の表示を戻す。iPad に「停止した」と通知すると iPad はマイクを停止するので、諦めるまでは通知しない。
    private func confirmVoiceInputStarted(_ message: ControlMessage, requestCount: Int, retriesLeft: Int) {
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime) { [weak self] in
            guard let self, voiceInputRequests.isCurrent(requestCount) else { return }
            if TypelessMonitor.isRecording() {
                voiceInputRequests.settle(requestCount)
                control?.send(.control(.voiceInputState(isActive: true)))
            } else if retriesLeft > 0 {
                Self.logger.notice("Typeless が音声入力を開始しないので、ショートカットを押し直す (残り \(retriesLeft) 回)")
                inputQueue.async { [injector] in injector.handle(message) }
                confirmVoiceInputStarted(message, requestCount: requestCount, retriesLeft: retriesLeft - 1)
            } else {
                Self.logger.notice("Typeless が音声入力を開始しなかった")
                voiceInputRequests.settle(requestCount)
                control?.send(.control(.voiceInputState(isActive: false)))
                microphone?.endListening()
            }
        }
    }

    private func beginSession(on channel: MessageChannel, deviceName: String) {
        // 新しい iPad が接続したら古いセッションは破棄する。同時に操作されると入力が混ざるため
        closeSession()
        control = channel
        isUsingPadMicrophone = false
        listeningRequest = nil
        videoFrameRate = PreferredFrameRate.normal
        macAudioCodec = .pcm
        isVideoQualityReduced = false
        // 再接続の原因を後から追えるよう、どの経路 (Wi-Fi のネットワークか、Wi-Fi の直接通信 awdl か) かも記録する
        let interface = channel.connection.currentPath?.availableInterfaces.first?.name ?? "不明"
        Self.logger.notice("接続: \(deviceName, privacy: .public) (\(interface, privacy: .public))")
        didOpenAudioCaptureSettings = false
        // 前の iPad が拡大していた範囲を引き継がない。拡大していれば iPad が再リクエストする
        videoRegion = .full
        typeless?.start()
        microphoneStop?.cancel()
        microphoneStop = nil
        microphone?.start()
        // ヘルパーアプリがデバイスを作り、Typeless がそれをマイクの一覧に載せてから、Typeless に使わせる設定をする
        setUpTypelessMicrophone(after: 5)
        channel.send(.control(.welcome(hostName: hostName, status: currentStatus())))
        channel.send(.control(.voiceInputState(isActive: TypelessMonitor.isRecording())))
        sendDisplays()
        if let inputMode {
            channel.send(.control(.macInputMode(inputMode)))
        }
        if isScreenLocked {
            channel.send(.control(.macScreenLocked(true)))
        }
        if let commit = BuildCommit.current() {
            channel.send(.control(.buildCommit(commit)))
        }
        onBuildMismatch(nil)
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
        // 受信確認 (ACK) で、回線に入りきらないフレームを送信せずに破棄する
        channel.send(.control(.acknowledgeVideoFrames))
        // 新しい映像の接続では、ビットレートを上限から測り直すので、画質を下げた通知も初期状態に戻す
        isVideoQualityReduced = false
        let status = currentStatus()
        Self.logger.info("映像のリクエスト: \(maxWidth)x\(maxHeight)、画面収録=\(status.canCaptureScreen)、アクセシビリティ=\(status.canControlInput)")
        control?.send(.control(.hostStatus(status)))
        guard status.canCaptureScreen else { return }
        // スリープ中のディスプレイはキャプチャできないことがあるので、開始前に復帰させる。開始できずに接続の張り直しが続くときは、iPad が張り直す間隔を延ばしていく
        keepDisplayAwake(true)
        startStreamer(on: channel)
        startStatsTimer()
    }

    private func startStreamer(on channel: MessageChannel) {
        // ディスプレイを切り替えて作り直しても回線は同じなので、ACK を返す iPad かどうかと、下げたビットレートを引き継ぐ。測り直す間に低速な回線で遅延が蓄積しないように
        let previous = streamer.flatMap { $0.channel === channel ? $0 : nil }
        streamer?.stop()
        let displayID = selection.shownID ?? CGMainDisplayID()
        let streamer = ScreenStreamer(
            channel: channel, displayID: displayID, maxWidth: videoMaxSize.width, maxHeight: videoMaxSize.height, region: videoRegion,
            isAcknowledged: previous?.isAcknowledged ?? false, initialBitRate: previous?.currentBitRate, initialRoundTrip: previous?.currentRoundTrip,
            frameRate: videoFrameRate,
            onQualityChange: { [weak self] isReduced in
                guard let self else { return }
                queue.async { self.videoQualityChanged(isReduced) }
            }
        )
        self.streamer = streamer
        streamedDisplay = DisplayLayout(of: displayID)
        Task {
            do {
                try await streamer.start()
                self.queue.async {
                    if self.streamer === streamer { self.missingDisplayRetries = 0 }
                }
            } catch {
                Self.logger.error("ディスプレイのキャプチャを開始できません: \(error, privacy: .public)")
                let isDisplayMissing = (error as? ScreenStreamerError) == .displayNotFound
                self.queue.async {
                    guard self.streamer === streamer else { return }
                    // ScreenCaptureKit の一覧にないディスプレイ (CoreGraphics からは見えていてもキャプチャできないもの) で黒画面のまま繰り返さないよう、メインディスプレイを表示する
                    if isDisplayMissing, let video = self.video, self.selection.fallBackToMain() {
                        self.applyShownDisplay()
                        self.sendDisplays()
                        self.startStreamer(on: video)
                        // 接続直後のディスプレイは、CoreGraphics から見えても ScreenCaptureKit の一覧に載るまで少しかかる。少し待って選択されたディスプレイに戻れるかを再確認する
                        if self.missingDisplayRetries < 3 {
                            self.missingDisplayRetries += 1
                            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshDisplays() }
                        }
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
        Self.logger.notice("iPad のリクエストにより、映像を毎秒 \(rate) フレームまでにする")
        // キャプチャ間隔とエンコーダの想定は作成時に決まるので、作り直す
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
        Self.logger.notice("回線に合わせて画質を\(isReduced ? "下げた" : "戻した", privacy: .public)ことを iPad に通知する")
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
        // 1 回の変更で続けて通知されることがあるので、落ち着いてから 1 回だけ読み直す
        let change = DispatchWorkItem { [weak self] in self?.refreshDisplays() }
        displayChange = change
        queue.asyncAfter(deadline: .now() + 0.5, execute: change)
    }

    /// ディスプレイ名は NSScreen からしか取得できないので、メインスレッドで取得してから受け取る。
    private func refreshDisplays() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = MainActor.assumeIsolated { DisplayCatalog.current() }
            queue.async { self.displaysChanged(snapshot) }
        }
    }

    /// 選択されたディスプレイが取り外されたらメインディスプレイを表示し、再接続されたらまた選択されたディスプレイを表示する。
    /// キャプチャは開始時のディスプレイサイズのまま続き、タッチ位置とずれるので、表示するディスプレイやその解像度・配置が変わったら作り直す。
    private func displaysChanged(_ snapshot: DisplayCatalog.Snapshot) {
        usableAreas = snapshot.usableAreas
        let update = selection.update(snapshot.displays, preferred: preferredDisplayID())
        if update.isShownChanged {
            applyShownDisplay()
        }
        if update.needsAnnouncement {
            Self.logger.notice("表示できるディスプレイ: \(snapshot.displays.map(\.label).joined(separator: "、"), privacy: .public)")
            sendDisplays()
        }
        guard let video, streamer != nil, let shownID = selection.shownID, streamedDisplay != DisplayLayout(of: shownID) else { return }
        Self.logger.notice("Mac のディスプレイ構成が変わったので、キャプチャを作り直す")
        startStreamer(on: video)
    }

    private func selectDisplay(_ id: CGDirectDisplayID) {
        // 選択直前のアプリ切り替えで待機中の「ウィンドウを追う」処理が、後から選択したディスプレイを切り替え直さないように
        activationCount += 1
        missingDisplayRetries = 0
        switchDisplay(to: id, reason: "表示するディスプレイを選択した", movesPointer: true)
    }

    /// 最前面のウィンドウを選択されたディスプレイへ移動し、そのディスプレイを表示する。ディスプレイをまたいでドラッグできない代わり。
    private func moveFrontWindow(to id: CGDirectDisplayID) {
        guard selection.contains(id) else {
            sendDisplays()
            return
        }
        activationCount += 1
        // Dock やメニューバーのサイズや表示設定を変えてもディスプレイ構成の通知は来ないので、移動直前に使用可能範囲を読み直す
        DispatchQueue.main.async {
            let usableAreas = MainActor.assumeIsolated { DisplayCatalog.current().usableAreas }
            // アクセシビリティの操作は相手アプリの応答を待つので、サーバーのキューの外で行う
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let isMoved = DisplayCatalog.moveFrontWindow(to: id, usableAreas: usableAreas)
                guard let self else { return }
                queue.async {
                    Self.logger.notice("最前面のウィンドウをディスプレイ \(id) へ: \(isMoved ? "移動した" : "移動できない", privacy: .public)")
                    guard isMoved else { return }
                    self.switchDisplay(to: id, reason: "最前面のウィンドウを移動したディスプレイを表示する", movesPointer: true)
                }
            }
        }
    }

    /// Dock を表示してキーボードで選択できるようにする。表示していないディスプレイに出ると iPad では見えないまま Dock に入力が移るので、先に Dock があるディスプレイを表示する。
    private func showDock() {
        if selection.hasMultipleDisplays, let id = DisplayCatalog.dockDisplay(), id != selection.shownID {
            switchDisplay(to: id, reason: "Dock があるディスプレイを表示する", movesPointer: false)
        }
        inputQueue.async { [injector] in
            RemoteKeys.focusDock().forEach(injector.handle)
        }
    }

    /// 最前面に出たアプリのウィンドウが別のディスプレイにあれば、そのディスプレイを表示する。iPad のアプリ切り替えで選んだアプリが、表示していないディスプレイにあって見えないままにならないように。
    private func applicationActivated(_ pid: pid_t) {
        activationCount += 1
        let count = activationCount
        guard video != nil, selection.hasMultipleDisplays, pid != ProcessInfo.processInfo.processIdentifier else { return }
        // 最前面に出てからウィンドウが前面に来るまで少しかかる。アクセシビリティの問い合わせは相手の応答を待つので、サーバーのキューの外で行う
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
        switchDisplay(to: id, reason: "最前面に出たウィンドウがあるディスプレイを表示する", movesPointer: false)
    }

    /// ディスプレイを記憶して表示する。取り外したあとで再接続しても、そのディスプレイを表示する。
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
        // iPad は選択したディスプレイを先に表示したことにしているので、すでに表示していたときも現在の一覧を通知し直して食い違いを残さない
        guard result == .switched else {
            sendDisplays()
            return
        }
        applyShownDisplay()
        if movesPointer {
            inputQueue.async { [injector] in injector.moveToDisplayCenter() }
        }
        sendDisplays()
        if let video, streamer != nil {
            startStreamer(on: video)
        }
    }

    /// 表示するディスプレイが変わったときに、拡大の範囲とタッチの送信先ディスプレイを合わせる。
    private func applyShownDisplay() {
        // 前のディスプレイで拡大していた範囲は、別のディスプレイでは意味がない。iPad もディスプレイが変わると拡大を戻す
        videoRegion = .full
        let displayID = selection.shownID
        inputQueue.async { [injector] in injector.setDisplay(displayID) }
    }

    private func sendDisplays() {
        // Mac の前にいる人にも、iPad がどのディスプレイを見ているかを Host のメニューで表示する (ディスプレイが 2 台以上のときだけ)
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
        // 押し直しやヘルパーアプリの応答を待っているリクエストが、切断後に Typeless を開始しないようにする
        voiceInputRequests.cancelAll()
        onShownDisplayChange(nil)
        typeless?.stop()
        stopMacAudio()
        microphone?.endListening()
        // 再接続のたびにヘルパーアプリを起動し直すと、デバイスを作り直してチェックし終えるまで iPad のマイクを使えない。しばらく残しておく
        scheduleMicrophoneStop(after: 60)
        inputQueue.async { [injector] in injector.releaseAll() }
        onClientChange(nil)
    }

    private func keepDisplayAwake(_ isAwake: Bool) {
        if isAwake, displayAssertion == nil {
            // スリープ防止のアサーションは、すでにスリープしているディスプレイを復帰させない。表示開始時にユーザー操作があったと通知して復帰させる
            var activity = IOPMAssertionID(0)
            if IOPMAssertionDeclareUserActivity("iPad への画面配信を開始" as CFString, kIOPMUserActiveLocal, &activity) == kIOReturnSuccess {
                IOPMAssertionRelease(activity)
            }
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "iPad に画面を配信中" as CFString, &id) == kIOReturnSuccess {
                displayAssertion = id
            }
        } else if !isAwake, let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
    }

    /// ヘルパーアプリを停止する。Mac で直接 Typeless を使っている最中は、デバイスが消えて録音が途切れないよう、終了するまで待つ。
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

    /// 状態を iPad と Mac のメニューの両方に通知する。
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
