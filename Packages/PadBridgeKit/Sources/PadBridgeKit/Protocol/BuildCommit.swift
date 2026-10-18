import Foundation

/// アプリをビルドしたコミット (`just` のビルドが git から Info.plist に埋め込む)。
/// iPad アプリだけを更新して Mac の Host を古いままにすると、古い側の挙動を見て原因を取り違えるので、接続時に比較して通知する。
public enum BuildCommit {
    /// Info.plist に入っているコミット。Xcode からビルドしたときなど、不明なら nil。
    public static func current(in bundle: Bundle = .main) -> String? {
        known(bundle.object(forInfoDictionaryKey: "PadBridgeCommit") as? String)
    }

    /// 両方のコミットが判明していて異なるときだけ、不一致とする。
    public static func isMismatch(_ own: String?, _ other: String?) -> Bool {
        guard let own = known(own), let other = known(other) else { return false }
        return own != other
    }

    private static func known(_ commit: String?) -> String? {
        guard let commit, !commit.isEmpty, commit != "unknown", !commit.contains("$(") else { return nil }
        return commit
    }
}
