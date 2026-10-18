import AppKit
import Foundation
import Network
import os
import PadBridgeKit

/// Host につなぎ、iPad のマイクの音を受け取って `PadMicrophone` に渡す。Host との接続が切れたら、デバイスを消して終わる。
nonisolated final class RelayClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.mic", category: "relay")
    private let queue = DispatchQueue(label: "dev.void2610.padbridge.mic.relay")
    private let port: NWEndpoint.Port?
    private let token: String?
    private var channel: MessageChannel?
    private var microphone: PadMicrophone?
    private var terminationSources: [DispatchSourceSignal] = []

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        port = value(after: "--port").flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:))
        token = value(after: "--token")
    }

    func start() {
        // 終了の合図で終わらされたときも、作ったデバイスを Mac に残さない
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.finish() }
            source.resume()
            terminationSources.append(source)
        }
        queue.async { [self] in
            guard let port, let token else {
                Self.logger.error("Host の接続先が渡されていない")
                finish()
                return
            }
            let channel = MessageChannel(connection: NWConnection(host: .ipv4(.loopback), port: port, using: .padBridge()), queue: queue)
            self.channel = channel
            let microphone = PadMicrophone { [weak channel] isAuthorized in
                channel?.send(.control(.microphoneRelayStatus(isAuthorized: isAuthorized)))
            }
            self.microphone = microphone
            channel.start(
                onStateChange: { [weak self] state in
                    switch state {
                    case .ready:
                        channel.send(.control(.microphoneRelayHello(token: token)))
                        microphone.start()
                    // つなげない (Host が終わって待ち受けていない) ときは .waiting のまま待ち続けるので、それも終わる合図にする
                    case .failed, .cancelled, .waiting:
                        guard let self else { return }
                        queue.async { self.finish() }
                    default:
                        break
                    }
                },
                onMessage: { [weak self] message in
                    self?.handle(message)
                }
            )
        }
    }

    private func handle(_ message: WireMessage) {
        switch message {
        case let .audio(samples):
            microphone?.feed(samples)
        case let .control(.microphoneRelay(isListening)):
            if isListening {
                microphone?.beginListening { [weak channel] isUsingPadMicrophone in
                    channel?.send(.control(.microphoneRelayReady(isUsingPadMicrophone: isUsingPadMicrophone)))
                }
            } else {
                microphone?.endListening()
            }
        case .control(.microphoneRelayFinish):
            microphone?.finishListening { [weak channel] in
                channel?.send(.control(.microphoneRelayFinished))
            }
        default:
            break
        }
    }

    /// アクティビティモニタの「終了」やログアウトなど、Apple Event で終わらされるときに呼ぶ。作ったデバイスを Mac に残さない。
    func stopBeforeQuitting() {
        queue.sync {
            microphone?.stop()
            microphone = nil
        }
    }

    /// Host が終わったか、接続できなかった。作ったデバイスを消してから終わる。
    private func finish() {
        Self.logger.notice("Host との接続が切れたので終わる")
        // 自分が作ったものだけを消す。名前で探して消すと、入れ替わりに起動した補助アプリのデバイスまで消してしまう
        microphone?.stop()
        microphone = nil
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}
