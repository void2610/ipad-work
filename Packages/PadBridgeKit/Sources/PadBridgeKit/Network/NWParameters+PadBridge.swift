import Foundation
import Network
import Security

public enum PadBridgeService {
    public static let type = "_padbridge._tcp"
}

extension NWParameters {
    public static func padBridge(pairingCode: PairingCode) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let key = pairingCode.preSharedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("PadBridge".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        // 証明書を配らずに相互認証するため、PSK だけで成立する暗号スイートに限る
        sec_protocol_options_append_tls_ciphersuite(
            tlsOptions.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        // iPad がスリープや圏外で消えたとき、Mac 側の接続を早めに畳むため
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        let framerOptions = NWProtocolFramer.Options(definition: PadBridgeFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        return parameters
    }
}
