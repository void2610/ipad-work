@testable import PadBridgeKit
import Testing

struct BuildCommitTests {
    /// 両方が判明していて異なるときだけ不一致とし、Xcode からビルドした (unknown) 側や、置換されていない値とは比較しない。
    @Test func comparesOnlyKnownCommits() {
        #expect(BuildCommit.isMismatch("d13ef71", "a50ce48"))
        #expect(BuildCommit.isMismatch("d13ef71", "d13ef71-dirty"))
        #expect(!BuildCommit.isMismatch("d13ef71", "d13ef71"))
        #expect(!BuildCommit.isMismatch("d13ef71", "unknown"))
        #expect(!BuildCommit.isMismatch(nil, "d13ef71"))
        #expect(!BuildCommit.isMismatch("$(PADBRIDGE_COMMIT)", "d13ef71"))
        #expect(!BuildCommit.isMismatch("", "d13ef71"))
    }
}
