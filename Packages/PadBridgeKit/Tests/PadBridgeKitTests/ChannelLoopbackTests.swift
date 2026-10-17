import Foundation
import Network
@testable import PadBridgeKit
import Testing

/// 実際の TLS-PSK とフレーミングを、ループバックの TCP で通して確かめる。
struct ChannelLoopbackTests {
    @Test func sameCodeExchangesMessagesBothWays() async throws {
        let code = PairingCode.generate()
        let server = try await LoopbackServer(code: code)
        defer { server.stop() }

        let client = MessageChannel(connection: NWConnection(to: server.endpoint, using: .padBridge(pairingCode: code)), queue: .global())
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

    @Test func differentCodeFailsHandshake() async throws {
        let server = try await LoopbackServer(code: PairingCode.generate())
        defer { server.stop() }

        let client = MessageChannel(connection: NWConnection(to: server.endpoint, using: .padBridge(pairingCode: PairingCode.generate())), queue: .global())
        let states = AsyncStream.makeStream(of: NWConnection.State.self)
        client.start(onStateChange: { states.continuation.yield($0) }, onMessage: { _ in })
        defer { client.cancel() }

        var sawTLSFailure = false
        for await state in states.stream {
            if case .ready = state { break }
            if case let .failed(error) = state, case .tls = error { sawTLSFailure = true; break }
            if case let .waiting(error) = state, case .tls = error { sawTLSFailure = true; break }
        }
        #expect(sawTLSFailure)
    }
}

/// 受け取ったメッセージをそのまま送り返すサーバー。
private final class LoopbackServer: Sendable {
    let listener: NWListener
    let endpoint: NWEndpoint

    init(code: PairingCode) async throws {
        let listener = try NWListener(using: .padBridge(pairingCode: code), on: .any)
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
