import Foundation
import Network
import os
import Synchronization

/// `NWConnection` の上で `WireMessage` を送受信する。送信はどのスレッドから呼んでもよい。
public final class MessageChannel: Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.kit", category: "channel")
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let pendingSends = Mutex(0)

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// 送信要求済みだがまだネットワークに渡っていないメッセージの数。映像のフレーム破棄に使う。
    public var pendingSendCount: Int {
        pendingSends.withLock { $0 }
    }

    public func start(
        onStateChange: @escaping @Sendable (NWConnection.State) -> Void,
        onMessage: @escaping @Sendable (WireMessage) -> Void
    ) {
        connection.stateUpdateHandler = { [weak self] state in
            onStateChange(state)
            if case .ready = state {
                self?.receiveNext(onMessage)
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: WireMessage) {
        let encoded: (type: UInt32, payload: Data)
        do {
            encoded = try message.encoded()
        } catch {
            assertionFailure("エンコードできないメッセージ: \(error)")
            return
        }
        let framerMessage = NWProtocolFramer.Message(padBridgeMessageType: encoded.type)
        let context = NWConnection.ContentContext(identifier: "PadBridgeMessage", metadata: [framerMessage])
        pendingSends.withLock { $0 += 1 }
        connection.send(content: encoded.payload, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.pendingSends.withLock { $0 -= 1 }
        })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveNext(_ onMessage: @escaping @Sendable (WireMessage) -> Void) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            guard error == nil else {
                // 受信をやめたまま開いていると、何も届かないのに再接続も始まらない。閉じて、再接続する側に通知する
                connection.cancel()
                return
            }
            guard let framerMessage = context?.protocolMetadata(definition: PadBridgeFramer.definition) as? NWProtocolFramer.Message else {
                // 相手が閉じた
                connection.cancel()
                return
            }
            // 区切りは framer が切り出しているので、相手が新しいビルドで送ってきた未知のメッセージはスキップして続行できる
            do {
                try onMessage(WireMessage(type: framerMessage.padBridgeMessageType, payload: content ?? Data()))
            } catch {
                Self.logger.notice("解釈できないメッセージをスキップした (種類 \(framerMessage.padBridgeMessageType)): \(error, privacy: .public)")
            }
            receiveNext(onMessage)
        }
    }
}
