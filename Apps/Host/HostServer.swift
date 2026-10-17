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

    init(
        hostName: String,
        doubleClickInterval: TimeInterval,
        onClientChange: @escaping @Sendable (String?) -> Void,
        onListenerChange: @escaping @Sendable (String) -> Void
    ) {
        self.hostName = hostName
        self.onClientChange = onClientChange
        self.onListenerChange = onListenerChange
        injector = InputInjector(doubleClickInterval: doubleClickInterval)
    }

    func start() {
        queue.async { self.startListener() }
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
        case let .insertText(text):
            // 入力内容そのものはログに残さない
            Self.logger.info("文字入力を受信: \(text.count) 文字")
            inputQueue.async { TextInserter.insert(text) }
        case let .voiceInput(isActive):
            Self.logger.info("Typeless の音声入力: \(isActive ? "開始" : "完了", privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case let .desktopSwipe(direction):
            Self.logger.info("3 本指スワイプ: \(direction.rawValue, privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .mouseMove, .mouseButton, .scroll, .key:
            Self.logger.debug("操作を受信: \(String(describing: message), privacy: .public)")
            inputQueue.async { [injector] in injector.handle(message) }
        case .hello, .welcome, .hostStatus:
            break
        }
    }

    private func beginSession(on channel: MessageChannel, deviceName: String) {
        // 新しい iPad が来たら古いセッションは捨てる。同時に操作されると入力が混ざるため
        closeSession()
        control = channel
        Self.logger.info("接続: \(deviceName, privacy: .public)")
        channel.send(.control(.welcome(hostName: hostName, status: Self.currentStatus())))
        onClientChange(deviceName)
    }

    private func beginVideo(on channel: MessageChannel, maxWidth: Int, maxHeight: Int) {
        guard control != nil else {
            channel.cancel()
            return
        }
        stopVideo()
        video = channel
        let status = Self.currentStatus()
        Self.logger.info("映像の要求: \(maxWidth)x\(maxHeight)、画面収録=\(status.canCaptureScreen)、アクセシビリティ=\(status.canControlInput)")
        control?.send(.control(.hostStatus(status)))
        guard status.canCaptureScreen else { return }
        let streamer = ScreenStreamer(channel: channel, maxWidth: maxWidth, maxHeight: maxHeight)
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
        Self.logger.info("切断")
        control.cancel()
        self.control = nil
        inputQueue.async { [injector] in injector.releaseAll() }
        onClientChange(nil)
    }

    private static func currentStatus() -> HostStatus {
        HostStatus(canCaptureScreen: CGPreflightScreenCaptureAccess(), canControlInput: AXIsProcessTrusted())
    }
}
