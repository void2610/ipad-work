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
    /// iPad の設定でこのアプリにローカルネットワークが許可されておらず、Mac を探索できない。
    private(set) var isLocalNetworkDenied = false

    private static let lastHostKey = "lastHostName"
    private var browser: NWBrowser?
    // ユーザーが自分で切断したあとは、見つかった Mac に勝手に再接続しない
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
                // mDNSResponder が再起動したときなどに失敗する。そのままだと、アプリを再起動するまで Mac が見つからない
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

    /// 接続中の Mac の名前が消え、同名に「 (2)」が付いた別名が現れたら、そちらへ再接続する (前の Host の登録が残っている間に再起動すると名前が変わる)。
    private func followRenamedHost() {
        guard let session, session.phase != .connected, !hosts.contains(where: { $0.name == session.host.name }) else { return }
        let base = PadBridgeService.baseName(session.host.name)
        guard let renamed = hosts.first(where: { PadBridgeService.baseName($0.name) == base }) else { return }
        connect(to: renamed)
    }
}
