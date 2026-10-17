import Foundation
import Network
import Observation
import PadBridgeKit
import UIKit

/// 1 台の Mac との接続。操作用と映像用の 2 本の接続を持つ。
@Observable
final class HostSession {
    enum End {
        case rejectedPairingCode
        case lost(String)
    }

    enum Phase {
        case connecting
        case connected
    }

    let host: DiscoveredHost
    let renderer = VideoRenderer()
    private(set) var phase = Phase.connecting
    private(set) var hostStatus: HostStatus?
    private(set) var videoSize = CGSize.zero

    private let pairingCode: PairingCode
    private let onEnd: (End) -> Void
    // 映像の受信と復号を操作の通信から切り離し、映像が重くても操作が遅れないようにする
    private let videoQueue = DispatchQueue(label: "dev.void2610.padbridge.pad.video")
    private var control: MessageChannel?
    private var video: MessageChannel?
    private var isFinished = false

    init(host: DiscoveredHost, pairingCode: PairingCode, onEnd: @escaping (End) -> Void) {
        self.host = host
        self.pairingCode = pairingCode
        self.onEnd = onEnd
    }

    func start() {
        let control = MessageChannel(connection: NWConnection(to: host.endpoint, using: .padBridge(pairingCode: pairingCode)), queue: .main)
        self.control = control
        renderer.onNeedsKeyFrame = { [control] in
            control.send(.control(.requestKeyFrame))
        }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in self?.videoSize = size }
        }
        control.start(
            onStateChange: { [weak self] state in
                MainActor.assumeIsolated { self?.controlStateChanged(state) }
            },
            onMessage: { [weak self] message in
                MainActor.assumeIsolated { self?.handleControl(message) }
            }
        )
    }

    func send(_ message: ControlMessage) {
        control?.send(.control(message))
    }

    func close() {
        isFinished = true
        control?.cancel()
        video?.cancel()
    }

    private func finish(_ end: End) {
        guard !isFinished else { return }
        close()
        onEnd(end)
    }

    private func controlStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(.hello(role: .control, deviceName: UIDevice.current.name, maxVideoWidth: 0, maxVideoHeight: 0))
        case let .waiting(error):
            if case .tls = error { finish(.rejectedPairingCode) }
        case let .failed(error):
            if case .tls = error {
                finish(.rejectedPairingCode)
            } else {
                finish(.lost("\(host.name) に接続できませんでした（\(error.localizedDescription)）"))
            }
        case .cancelled:
            finish(.lost("\(host.name) との接続が切れました。"))
        default:
            break
        }
    }

    private func handleControl(_ message: WireMessage) {
        guard case let .control(message) = message else { return }
        switch message {
        case let .welcome(_, status):
            hostStatus = status
            phase = .connected
            startVideo()
        case let .hostStatus(status):
            hostStatus = status
        default:
            break
        }
    }

    private func startVideo() {
        let channel = MessageChannel(connection: NWConnection(to: host.endpoint, using: .padBridge(pairingCode: pairingCode)), queue: videoQueue)
        video = channel
        let size = Self.maxVideoSize()
        let renderer = renderer
        channel.start(
            onStateChange: { [weak self] state in
                switch state {
                case .ready:
                    channel.send(.control(.hello(role: .video, deviceName: "", maxVideoWidth: size.width, maxVideoHeight: size.height)))
                case .failed, .cancelled:
                    Task { @MainActor in self?.finish(.lost("映像の接続が切れました。")) }
                default:
                    break
                }
            },
            onMessage: { message in
                renderer.handle(message)
            }
        )
    }

    /// 横向きにしたときの画面の画素数。Mac はこれに収まる大きさで画面を取り込む。
    private static func maxVideoSize() -> (width: Int, height: Int) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let bounds = screen?.nativeBounds ?? CGRect(x: 0, y: 0, width: 2048, height: 2732)
        return (Int(max(bounds.width, bounds.height)), Int(min(bounds.width, bounds.height)))
    }
}
