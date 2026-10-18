import Network

/// ローカルネットワークの許可を、Bonjour のブラウズの状態から判定する。許可を直接読む API はない (TN3179)。
public enum LocalNetworkAccess {
    /// 許可がないと、検索は `kDNSServiceErr_PolicyDenied` (-65570) で止まる。
    public static func isDenied(_ state: NWBrowser.State) -> Bool {
        switch state {
        case let .waiting(error), let .failed(error):
            error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        default:
            false
        }
    }
}
