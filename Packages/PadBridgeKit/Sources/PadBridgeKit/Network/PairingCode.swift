import CryptoKit
import Foundation

/// Mac が発行し、iPad に一度だけ手入力してもらう共有の秘密。TLS-PSK の鍵の元になる。
public struct PairingCode: Sendable, Hashable {
    // 手入力で取り違えやすい I・L・O・0・1 を除いた文字だけを使う
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    // 31 文字 × 10 桁で約 49 ビット。家庭内 LAN で、ハンドシェイクを盗聴されて総当たりされる現実的な脅威には十分な長さ
    static let length = 10

    public let value: String

    public init?(_ input: String) {
        let normalized = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == Self.length, normalized.allSatisfy(Self.alphabet.contains) else { return nil }
        value = normalized
    }

    public static func generate() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let characters = (0 ..< length).map { _ in alphabet.randomElement(using: &generator)! }
        return PairingCode(String(characters))!
    }

    public var formatted: String {
        "\(value.prefix(5))-\(value.suffix(5))"
    }

    var preSharedKey: Data {
        let key = SymmetricKey(data: Data(value.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data("PadBridge-PSK-v1".utf8), using: key))
    }
}
