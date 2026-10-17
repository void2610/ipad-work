@testable import PadBridgeKit
import Testing

struct PassThroughGateTests {
    /// (ほかのアプリが読んでいるか, iPad から聞き取っているか) を順に渡し、流すかの答えを並べる。
    private func decisions(_ gate: inout PassThroughGate, _ states: [(isRead: Bool, isPadListening: Bool)]) -> [Bool] {
        states.map { gate.shouldPassThrough(isRead: $0.isRead, isPadListening: $0.isPadListening) }
    }

    /// iPad から話していない間に読まれたら Mac のマイクを流し、読まれなくなったらやめる。
    @Test func passesThroughOnlyWhileRead() {
        var gate = PassThroughGate()
        let result = decisions(&gate, [(false, false), (true, false), (false, false)])
        #expect(result == [false, true, false])
    }

    /// iPad から聞き取っている間は、iPad の声だけを流す。
    @Test func padListeningWins() {
        var gate = PassThroughGate()
        let before = decisions(&gate, [(true, false)])
        gate.padListeningBegan()
        let during = decisions(&gate, [(true, true)])
        #expect(before == [true])
        #expect(during == [false])
    }

    /// iPad からの聞き取りが終わっても Typeless が読み終えるまでは流さず、次に読まれたら流す。
    @Test func waitsUntilReadingStopsAfterPadListening() {
        var gate = PassThroughGate()
        gate.padListeningBegan()
        let result = decisions(&gate, [(true, true), (true, false), (false, false), (true, false)])
        #expect(result == [false, false, false, true])
    }

    /// 自分で読んでいる間 (iPad から聞き取り中) に読まれなくなっても、聞き取りが終わるまでは区切りにしない。
    @Test func readingStopWhileListeningDoesNotRelease() {
        var gate = PassThroughGate()
        gate.padListeningBegan()
        let result = decisions(&gate, [(false, true), (true, false)])
        #expect(result == [false, false])
    }
}
