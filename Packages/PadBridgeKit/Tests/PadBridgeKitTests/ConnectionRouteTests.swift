import Network
@testable import PadBridgeKit
import Testing

struct ConnectionRouteTests {
    /// AWDL はインターフェースの種類が Wi-Fi でも、名前でピアツーピア通信と見分ける。
    @Test func labelsRoutes() {
        #expect(ConnectionRoute.label(interfaceName: "awdl0", type: .wifi) == "Wi-Fi ピアツーピア (AWDL)")
        #expect(ConnectionRoute.label(interfaceName: "en0", type: .wifi) == "Wi-Fi")
        #expect(ConnectionRoute.label(interfaceName: "en7", type: .wiredEthernet) == "有線 LAN")
        #expect(ConnectionRoute.label(interfaceName: "lo0", type: .loopback) == "ループバック (同じ機器内)")
        #expect(ConnectionRoute.label(interfaceName: "utun3", type: .other) == "utun3")
    }
}
