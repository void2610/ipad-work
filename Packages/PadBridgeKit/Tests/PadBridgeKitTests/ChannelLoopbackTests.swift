import Foundation
import Network
@testable import PadBridgeKit
import Testing

/// 実際のフレーミングを、ループバックの TCP で通して確かめる。
struct ChannelLoopbackTests {
    @Test func messagesRoundTripBothWays() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }

        let client = MessageChannel(connection: NWConnection(to: server.endpoint, using: .padBridge()), queue: .global())
        let replies = AsyncStream.makeStream(of: WireMessage.self)
        client.start(onStateChange: { _ in }, onMessage: { replies.continuation.yield($0) })
        defer { client.cancel() }

        let big = VideoFrame(isKeyFrame: false, presentationTimeMicros: 42, data: Data((0 ..< 300_000).map { UInt8($0 % 251) }))
        client.send(.control(.insertText("日本語のテキスト")))
        client.send(.videoFrame(big))

        var iterator = replies.stream.makeAsyncIterator()
        #expect(await iterator.next() == .control(.insertText("日本語のテキスト")))
        #expect(await iterator.next() == .videoFrame(big))
    }

    /// Mac と iPad の片方だけが新しいビルドのとき、知らないメッセージで接続を閉じてつなぎ直しを繰り返さない。
    @Test func skipsMessagesFromNewerBuild() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }

        let client = MessageChannel(connection: NWConnection(to: server.endpoint, using: .padBridge()), queue: .global())
        let replies = AsyncStream.makeStream(of: WireMessage.self)
        client.start(
            onStateChange: { state in
                switch state {
                case .failed, .cancelled: replies.continuation.finish()
                default: break
                }
            },
            onMessage: { replies.continuation.yield($0) }
        )
        defer { client.cancel() }

        client.sendRaw(type: 99, payload: Data([1, 2, 3]))
        client.sendRaw(type: 1, payload: Data(#"{"futureFeature":{}}"#.utf8))
        client.send(.control(.requestKeyFrame))

        var iterator = replies.stream.makeAsyncIterator()
        #expect(await iterator.next() == .control(.requestKeyFrame))
    }

    /// 相手が閉じたら、こちらもすぐ閉じて切断に気づく (Mac はこれで iPad が離れたことを知る)。キープアライブで気づくのを待たない。
    @Test func closesWhenPeerCloses() async throws {
        let started = ContinuousClock.now
        let listener = try NWListener(using: .padBridge(), on: .any)
        let ready = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { ready.continuation.yield($0) }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state { connection.cancel() }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        for await state in ready.stream {
            if case .ready = state { break }
        }

        let client = MessageChannel(connection: NWConnection(to: .hostPort(host: "127.0.0.1", port: listener.port!), using: .padBridge()), queue: .global())
        let closed = AsyncStream.makeStream(of: Void.self)
        client.start(
            onStateChange: { state in
                switch state {
                case .failed, .cancelled: closed.continuation.yield()
                default: break
                }
            },
            onMessage: { _ in }
        )
        defer { client.cancel() }

        var iterator = closed.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

private extension MessageChannel {
    /// 新しいビルドが送るような、このビルドの知らないメッセージを送る。
    func sendRaw(type: UInt32, payload: Data) {
        let context = NWConnection.ContentContext(identifier: "PadBridgeMessage", metadata: [NWProtocolFramer.Message(padBridgeMessageType: type)])
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// 受け取ったメッセージをそのまま送り返すサーバー。
extension ChannelLoopbackTests {
    /// 壊れた区切り (巨大な長さ) を受け取ったら、受け手は閉じたと分かる。黙って受け取るのをやめると、つながったまま何も届かなくなり、つなぎ直しも始まらない。
    @Test func closesOnMalformedFrame() async throws {
        let listener = try NWListener(using: .padBridge(), on: .any)
        let ready = AsyncStream.makeStream(of: NWListener.State.self)
        let ended = AsyncStream.makeStream(of: String.self)
        listener.stateUpdateHandler = { ready.continuation.yield($0) }
        listener.newConnectionHandler = { connection in
            let channel = MessageChannel(connection: connection, queue: .global())
            channel.start(
                onStateChange: { state in
                    switch state {
                    case .failed: ended.continuation.yield("failed")
                    case .cancelled: ended.continuation.yield("cancelled")
                    default: _ = channel
                    }
                },
                onMessage: { _ in }
            )
        }
        listener.start(queue: .global())
        for await state in ready.stream {
            if case .ready = state { break }
        }
        defer { listener.cancel() }

        // 区切りのない素の TCP で、長さに上限を超える値を入れた見出しを送る
        let raw = NWConnection(to: .hostPort(host: "127.0.0.1", port: listener.port!), using: .tcp)
        raw.start(queue: .global())
        defer { raw.cancel() }
        raw.send(content: Data([0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]), completion: .contentProcessed { _ in })

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = ended.stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(result != nil, "3 秒たっても受け手が閉じたと分からない")
    }
}

private final class LoopbackServer: Sendable {
    let listener: NWListener
    let endpoint: NWEndpoint

    init() async throws {
        let listener = try NWListener(using: .padBridge(), on: .any)
        let ready = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { ready.continuation.yield($0) }
        listener.newConnectionHandler = { connection in
            let channel = MessageChannel(connection: connection, queue: .global())
            channel.start(onStateChange: { _ in _ = channel }, onMessage: { channel.send($0) })
        }
        listener.start(queue: .global())
        for await state in ready.stream {
            if case .ready = state { break }
            if case let .failed(error) = state { throw error }
        }
        self.listener = listener
        endpoint = .hostPort(host: "127.0.0.1", port: listener.port!)
    }

    func stop() {
        listener.cancel()
    }
}
