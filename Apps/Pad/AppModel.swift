import Foundation
import Network
import Observation
import PadBridgeKit
import UIKit

struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint

    var id: String { name }
}

@Observable
final class AppModel {
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var session: HostSession?

    private static let lastHostKey = "lastHostName"
    private var browser: NWBrowser?
    // 利用者が自分で切断したあとは、見つかった Mac に勝手につなぎ直さない
    private var isAutoConnectSuppressed = false

    init() {
        startBrowsing()
        autoConnectIfPossible()
    }

    func select(_ host: DiscoveredHost) {
        connect(to: host)
    }

    func disconnect() {
        isAutoConnectSuppressed = true
        session?.close()
        session = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func setForeground(_ isForeground: Bool) {
        session?.setForeground(isForeground)
    }

    private func connect(to host: DiscoveredHost) {
        session?.close()
        isAutoConnectSuppressed = false
        UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
        let session = HostSession(host: host)
        self.session = session
        session.start()
        // 操作中に iPad が自動ロックされないようにする
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func autoConnectIfPossible() {
        guard session == nil, !isAutoConnectSuppressed, let host = preferredHost() else { return }
        connect(to: host)
    }

    private func preferredHost() -> DiscoveredHost? {
        #if DEBUG
            // 実機・シミュレータでの確認用に、起動引数で接続先を決め打ちできるようにしている
            let defaults = UserDefaults.standard
            if let port = defaults.string(forKey: "PadBridgeTestPort").flatMap(NWEndpoint.Port.init(_:)) {
                // シミュレータは Mac とネットワークを共有しているので、Mac のループバックへ直接つなげる
                return DiscoveredHost(name: "テスト用 Host", endpoint: .hostPort(host: "127.0.0.1", port: port))
            }
            if let name = defaults.string(forKey: "PadBridgeTestHostName") {
                return hosts.first { $0.name == name }
            }
        #endif
        let lastName = UserDefaults.standard.string(forKey: Self.lastHostKey)
        return hosts.first { $0.name == lastName } ?? (hosts.count == 1 ? hosts.first : nil)
    }

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PadBridgeService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            MainActor.assumeIsolated {
                self?.hosts = hosts.sorted { $0.name < $1.name }
                self?.autoConnectIfPossible()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
