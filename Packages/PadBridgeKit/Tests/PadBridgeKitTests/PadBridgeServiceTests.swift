@testable import PadBridgeKit
import Testing

struct PadBridgeServiceTests {
    /// Bonjour が重なりを避けて付けた番号だけを除き、名前そのものの括弧は残す。
    @Test(arguments: [
        ("MacBook Pro", "MacBook Pro"),
        ("MacBook Pro (2)", "MacBook Pro"),
        ("MacBook Pro (12)", "MacBook Pro"),
        ("Mac (仕事用)", "Mac (仕事用)"),
        ("Mac ()", "Mac ()"),
        ("Mac(2)", "Mac(2)"),
    ])
    func stripsBonjourConflictNumber(name: String, base: String) {
        #expect(PadBridgeService.baseName(name) == base)
    }
}
