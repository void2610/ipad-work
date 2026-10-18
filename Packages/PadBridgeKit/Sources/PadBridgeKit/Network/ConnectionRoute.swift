import Network

/// iPad と Mac がどの経路でつながっているか。Wi-Fi の直接通信 (awdl) はネットワークを通さない分、揺れ方が違うので、「接続の状態」に出す。
public enum ConnectionRoute {
    public static func label(interfaceName name: String, type: NWInterface.InterfaceType) -> String {
        // awdl は種類としては Wi-Fi なので、名前で見分ける
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
