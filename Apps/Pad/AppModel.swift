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
    var pairingTarget: DiscoveredHost?
    private(set) var pairingError: String?
    private(set) var errorMessage: String?
    let dictation = DictationController()

    private let keychain = KeychainStore(service: "dev.void2610.padbridge.pad")
    private var browser: NWBrowser?
    // バックグラウンドで接続が切れたあと、前面に戻ったら同じ Mac につなぎ直すために覚えておく
    private var hostToResume: DiscoveredHost?
    private var hasAutoConnected = false

    init() {
        startBrowsing()
        autoConnectForTesting()
    }

    func select(_ host: DiscoveredHost) {
        errorMessage = nil
        guard let code = storedCode(for: host) else {
            pairingError = nil
            pairingTarget = host
            return
        }
        connect(to: host, code: code)
    }

    func submitPairingCode(_ input: String, for host: DiscoveredHost) {
        guard let code = PairingCode(input) else {
            pairingError = "コードは 10 文字です（I・L・O・0・1 は使われません）。"
            return
        }
        keychain.set(code.value, forAccount: host.name)
        pairingTarget = nil
        connect(to: host, code: code)
    }

    func cancelPairing() {
        pairingTarget = nil
    }

    func forgetPairing(for host: DiscoveredHost) {
        keychain.remove(account: host.name)
    }

    func disconnect() {
        hostToResume = nil
        session?.close()
        session = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func reconnectIfNeeded() {
        guard session == nil, let host = hostToResume, let code = storedCode(for: host) else { return }
        // Bonjour の解決結果は作り直されるので、名前で引き直した最新の端点を使う
        let current = hosts.first { $0.name == host.name } ?? host
        connect(to: current, code: code)
    }

    /// 実機・シミュレータでの確認用。起動引数で指定した Mac へ、指定したコードで自動でつなぐ。キーチェーンには保存しない。
    private func autoConnectForTesting() {
        #if DEBUG
            let defaults = UserDefaults.standard
            // Bonjour を通さずに Mac のループバックへつなぐ指定。シミュレータは Mac とネットワークを共有している
            let direct = defaults.string(forKey: "PadBridgeTestPort").flatMap(NWEndpoint.Port.init(_:)).map {
                DiscoveredHost(name: "テスト用 Host", endpoint: .hostPort(host: "127.0.0.1", port: $0))
            }
            let named = defaults.string(forKey: "PadBridgeTestHostName").flatMap { name in hosts.first { $0.name == name } }
            guard !hasAutoConnected, let host = direct ?? named,
                  let code = defaults.string(forKey: "PadBridgeTestPairingCode").flatMap(PairingCode.init)
            else { return }
            hasAutoConnected = true
            connect(to: host, code: code)
        #endif
    }

    private func storedCode(for host: DiscoveredHost) -> PairingCode? {
        keychain.string(forAccount: host.name).flatMap(PairingCode.init)
    }

    private func connect(to host: DiscoveredHost, code: PairingCode) {
        session?.close()
        errorMessage = nil
        let session = HostSession(host: host, pairingCode: code) { [weak self] end in
            self?.sessionEnded(end, host: host)
        }
        self.session = session
        hostToResume = host
        session.start()
        // 操作中に iPad が自動ロックされると、接続も映像も切れてしまう
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func sessionEnded(_ end: HostSession.End, host: DiscoveredHost) {
        session = nil
        UIApplication.shared.isIdleTimerDisabled = false
        switch end {
        case .rejectedPairingCode:
            hostToResume = nil
            keychain.remove(account: host.name)
            pairingError = "ペアリングコードが一致しませんでした。Mac のメニューに表示されているコードを入力してください。"
            pairingTarget = host
        case let .lost(reason):
            errorMessage = reason
        }
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
                self?.autoConnectForTesting()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
