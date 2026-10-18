import Foundation

/// アプリを組み立てたコミット (`just` の組み立てが git から Info.plist に入れる)。
/// iPad アプリだけを入れ替えて Mac の Host を古いままにすると、古い側の動きを見て原因を取り違えるので、つないだときに比べて知らせる。
public enum BuildCommit {
    /// Info.plist に入っているコミット。Xcode から組み立てたときなど、分からなければ nil。
    public static func current(in bundle: Bundle = .main) -> String? {
        known(bundle.object(forInfoDictionaryKey: "PadBridgeCommit") as? String)
    }

    /// 両方のコミットが分かっていて違うときだけ、ずれているとする。
    public static func isMismatch(_ own: String?, _ other: String?) -> Bool {
        guard let own = known(own), let other = known(other) else { return false }
        return own != other
    }

    private static func known(_ commit: String?) -> String? {
        guard let commit, !commit.isEmpty, commit != "unknown", !commit.contains("$(") else { return nil }
        return commit
    }
}
