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
        // 相手が黙って消えたとき (圏外・スリープ) に、既定の 75 秒×8 回の確認を待たず、10 秒ほどで切れたと分かってつなぎ直す
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 4
        // 送っている最中に消えたときは確認が送られず、再送が届かないまま待つ時間で決まる
        tcpOptions.connectionDropTime = 10

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        let framerOptions = NWProtocolFramer.Options(definition: PadBridgeFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        return parameters
    }
}
