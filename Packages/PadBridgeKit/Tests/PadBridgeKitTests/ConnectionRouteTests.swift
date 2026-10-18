import Network
@testable import PadBridgeKit
import Testing

struct ConnectionRouteTests {
    /// awdl は種類が Wi-Fi でも、名前で直接通信と見分ける。
    @Test func labelsRoutes() {
        #expect(ConnectionRoute.label(interfaceName: "awdl0", type: .wifi) == "Wi-Fi の直接通信 (awdl)")
        #expect(ConnectionRoute.label(interfaceName: "en0", type: .wifi) == "Wi-Fi のネットワーク")
        #expect(ConnectionRoute.label(interfaceName: "en7", type: .wiredEthernet) == "有線のネットワーク")
        #expect(ConnectionRoute.label(interfaceName: "lo0", type: .loopback) == "同じ機器の中 (ループバック)")
        #expect(ConnectionRoute.label(interfaceName: "utun3", type: .other) == "utun3")
    }
}
