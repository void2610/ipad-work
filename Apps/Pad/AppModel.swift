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
    /// iPad の設定で、このアプリにローカルネットワークが許可されていない。Mac を探せない。
    private(set) var isLocalNetworkDenied = false

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

    func releaseHeldInput() {
        session?.send(.releaseHeldInput)
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
        let lastName = UserDefaults.standard.string(forKey: Self.lastHostKey)
        return hosts.first { $0.name == lastName } ?? (hosts.count == 1 ? hosts.first : nil)
    }

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PadBridgeService.type, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            let isDenied = LocalNetworkAccess.isDenied(state)
            MainActor.assumeIsolated {
                self?.isLocalNetworkDenied = isDenied
                // mDNSResponder が起動し直したときなどに失敗する。そのままだと、アプリを起動し直すまで Mac が見つからない
                if case .failed = state, !isDenied, let self, let browser, browser === self.browser {
                    self.restartBrowsing()
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            MainActor.assumeIsolated {
                self?.hosts = hosts.sorted { $0.name < $1.name }
                self?.autoConnectIfPossible()
                self?.followRenamedHost()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, browser == nil else { return }
            startBrowsing()
        }
    }

    /// つないでいる Mac の名前が消え、同じ名前の「 (2)」付きの別名が現れたら、そちらへつなぎ直す (前の Host の登録が残っている間に起動し直すと名前が変わる)。
    private func followRenamedHost() {
        guard let session, session.phase != .connected, !hosts.contains(where: { $0.name == session.host.name }) else { return }
        let base = PadBridgeService.baseName(session.host.name)
        guard let renamed = hosts.first(where: { PadBridgeService.baseName($0.name) == base }) else { return }
        connect(to: renamed)
    }
}
