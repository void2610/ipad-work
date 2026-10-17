import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
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
    private let injector: InputInjector

    private var listener: NWListener?
    private var pending: [ObjectIdentifier: MessageChannel] = [:]
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var streamer: ScreenStreamer?
    // iPad が見ている範囲。映像の接続を張り直しても引き継ぐ
    private var videoRegion = VideoRegion.full
    private var typeless: TypelessMonitor?
    private var microphone: MicrophoneRelay?
    // 今の聞き取りで、既定の入力を iPad のマイクにしたか
    private var isUsingPadMicrophone = false
    private var typelessCannotReadPadMicrophone = false
    private var didOpenAudioCaptureSettings = false
    // iPad から音声入力の開始・完了が来るたびに増やし、古い要求の結果を知らせないようにする
    private var voiceInputRequestCount = 0

    init(
        hostName: String,
        doubleClickInterval: TimeInterval,
        keyRepeatDelay: TimeInterval,
        keyRepeatInterval: TimeInterval,
        onClientChange: @escaping @Sendable (String?) -> Void,
        onListenerChange: @escaping @Sendable (String) -> Void
    ) {
        self.hostName = hostName
        self.onClientChange = onClientChange
        self.onListenerChange = onListenerChange
        injector = InputInjector(queue: inputQueue, doubleClickInterval: doubleClickInterval, keyRepeatDelay: keyRepeatDelay, keyRepeatInterval: keyRepeatInterval)
    }

    func start() {
        queue.async {
            self.startListener()
            self.typeless = TypelessMonitor { [weak self] isRecording in
                guard let self else { return }
                queue.async { self.typelessRecordingChanged(isRecording) }
            }
            self.microphone = MicrophoneRelay(queue: self.queue) { [weak self] in
                guard let self else { return }
                control?.send(.control(.hostStatus(currentStatus())))
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.pending.values.forEach { $0.cancel() }
            self.pending.removeAll()
            self.closeSession()
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
                case let .failed(error): self?.onListenerChange("待ち受けに失敗: \(error.localizedDescription)")
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
        }
    }

    /// Mac で直接 Typeless を使ったときや、Typeless が自分で聞き取りを終えたときも、iPad のボタンの表示を合わせる。
    private func typelessRecordingChanged(_ isRecording: Bool) {
        Self.logger.notice("Typeless の聞き取り: \(isRecording ? "開始" : "終了", privacy: .public)")
        inputQueue.async { [injector] in injector.typelessRecordingChanged(isRecording) }
        control?.send(.control(.voiceInputState(isActive: isRecording)))
        if isRecording, isUsingPadMicrophone {
            checkTypelessAudioCaptureRefusal()
        }
        if !isRecording {
            microphone?.endListening()
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

    private func setTypelessCannotReadPadMicrophone(_ value: Bool) {
        guard typelessCannotReadPadMicrophone != value else { return }
        typelessCannotReadPadMicrophone = value
        control?.send(.control(.hostStatus(currentStatus())))
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
            reportVoiceInputAfterSettling(isActive: isActive)
            if isActive {
                // Typeless が録音を始める前に、既定の入力を iPad のマイクにしておく
                microphone?.beginListening { [weak self, inputQueue, injector] isUsingPadMicrophone in
                    self?.isUsingPadMicrophone = isUsingPadMicrophone
                    inputQueue.async { injector.handle(message) }
                }
            } else {
                // 送られてきた音を鳴らしきってから止めるよう、ためている分 (80ms) より少し長く待つ
                inputQueue.asyncAfter(deadline: .now() + 0.25) { [injector] in injector.handle(message) }
                let requestCount = voiceInputRequestCount
                queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime + 0.5) { [weak self] in
                    guard let self, requestCount == voiceInputRequestCount else { return }
                    microphone?.endListening()
                }
            }
        case let .desktopSwipe(direction):
            Self.logger.info("3 本指スワイプ: \(direction.rawValue, privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .mouseMove, .mouseButton, .scroll, .key:
            Self.logger.debug("操作を受信: \(String(describing: message), privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .hello, .welcome, .hostStatus, .voiceInputState, .microphoneRelayHello, .microphoneRelay, .microphoneRelayReady, .microphoneRelayStatus:
            break
        }
    }

    /// Typeless がショートカットに反応しなかったときは状態の変化が来ないので、待ってから実際の状態を知らせて iPad の表示を戻す。
    private func reportVoiceInputAfterSettling(isActive: Bool) {
        voiceInputRequestCount += 1
        let requestCount = voiceInputRequestCount
        queue.asyncAfter(deadline: .now() + TypelessToggle.settleTime) { [weak self] in
            guard let self, requestCount == voiceInputRequestCount else { return }
            let isRecording = TypelessMonitor.isRecording()
            control?.send(.control(.voiceInputState(isActive: isRecording)))
            // iPad のマイクに切り替えたのに聞き取りが始まらないなら、Typeless がこのデバイスを読めていない
            if isActive, isUsingPadMicrophone, !isRecording {
                setTypelessCannotReadPadMicrophone(true)
                microphone?.endListening()
            }
        }
    }

    private func beginSession(on channel: MessageChannel, deviceName: String) {
        // 新しい iPad が来たら古いセッションは捨てる。同時に操作されると入力が混ざるため
        closeSession()
        control = channel
        Self.logger.notice("接続: \(deviceName, privacy: .public)")
        didOpenAudioCaptureSettings = false
        // 前の iPad が拡大していた範囲を引き継がない。拡大していれば iPad が頼み直す
        videoRegion = .full
        typeless?.start()
        microphone?.start()
        channel.send(.control(.welcome(hostName: hostName, status: currentStatus())))
        channel.send(.control(.voiceInputState(isActive: TypelessMonitor.isRecording())))
        onClientChange(deviceName)
    }

    private func beginVideo(on channel: MessageChannel, maxWidth: Int, maxHeight: Int) {
        guard control != nil else {
            channel.cancel()
            return
        }
        stopVideo()
        video = channel
        let status = currentStatus()
        Self.logger.info("映像の要求: \(maxWidth)x\(maxHeight)、画面収録=\(status.canCaptureScreen)、アクセシビリティ=\(status.canControlInput)")
        control?.send(.control(.hostStatus(status)))
        guard status.canCaptureScreen else { return }
        let streamer = ScreenStreamer(channel: channel, maxWidth: maxWidth, maxHeight: maxHeight, region: videoRegion)
        self.streamer = streamer
        Task {
            do {
                try await streamer.start()
            } catch {
                Self.logger.error("画面の取り込みを開始できない: \(error, privacy: .public)")
                self.queue.async {
                    if self.streamer === streamer { self.stopVideo() }
                }
            }
        }
    }

    private func channelClosed(_ channel: MessageChannel) {
        pending[ObjectIdentifier(channel)] = nil
        if channel === control {
            closeSession()
        } else if channel === video {
            stopVideo()
        }
    }

    private func stopVideo() {
        streamer?.stop()
        streamer = nil
        video?.cancel()
        video = nil
    }

    private func closeSession() {
        stopVideo()
        guard let control else { return }
        Self.logger.notice("切断")
        control.cancel()
        self.control = nil
        typeless?.stop()
        microphone?.stop()
        inputQueue.async { [injector] in injector.releaseAll() }
        onClientChange(nil)
    }

    private func currentStatus() -> HostStatus {
        HostStatus(
            canCaptureScreen: CGPreflightScreenCaptureAccess(),
            canControlInput: AXIsProcessTrusted(),
            canRelayMicrophone: !(microphone?.isKnownUnauthorized ?? false),
            typelessCannotReadPadMicrophone: typelessCannotReadPadMicrophone
        )
    }
}
