import Network

/// iPad と Mac がどの経路で接続されているか。Wi-Fi のピアツーピア通信 (awdl) はネットワークを経由しない分ジッターの出方が違うので、「接続の状態」に表示する。
public enum ConnectionRoute {
    public static func label(interfaceName name: String, type: NWInterface.InterfaceType) -> String {
        // awdl はインターフェース種別としては Wi-Fi なので、名前で判別する
        if name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return "Wi-Fi ピアツーピア (AWDL)"
        }
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "有線 LAN"
        case .loopback: return "ループバック (同じ機器内)"
        default: return name
        }
    }
}
