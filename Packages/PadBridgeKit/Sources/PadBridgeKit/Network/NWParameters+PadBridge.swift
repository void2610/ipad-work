import Foundation
import Network

public enum PadBridgeService {
    public static let type = "_padbridge._tcp"
}

extension NWParameters {
    /// 認証も暗号化もしない。同じ LAN の機器だけを信頼する前提で、ペアリングの手間をなくしている。
    public static func padBridge() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        // iPad が圏外などで消えたとき、Mac 側の接続を早めに畳むため
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        let framerOptions = NWProtocolFramer.Options(definition: PadBridgeFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        return parameters
    }
}
