@testable import PadBridgeKit
import Testing

struct PassThroughGateTests {
    /// (ほかのアプリが読み取っているか, iPad から音声入力中か) を順に渡し、パススルーするかの結果を並べる。
    private func decisions(_ gate: inout PassThroughGate, _ states: [(isRead: Bool, isPadListening: Bool)]) -> [Bool] {
        states.map { gate.shouldPassThrough(isRead: $0.isRead, isPadListening: $0.isPadListening) }
    }

    /// iPad から話していない間に読み取られたら Mac のマイクをパススルーし、読み取られなくなったらやめる。
    @Test func passesThroughOnlyWhileRead() {
        var gate = PassThroughGate()
        let result = decisions(&gate, [(false, false), (true, false), (false, false)])
        #expect(result == [false, true, false])
    }

    /// iPad から音声入力している間は、iPad の音声だけをパススルーする。
    @Test func padListeningWins() {
        var gate = PassThroughGate()
        let before = decisions(&gate, [(true, false)])
        gate.padListeningBegan()
        let during = decisions(&gate, [(true, true)])
        #expect(before == [true])
        #expect(during == [false])
    }

    /// iPad からの音声入力が終わっても Typeless が読み取りを終えるまではパススルーせず、次に読み取られたらパススルーする。
    @Test func waitsUntilReadingStopsAfterPadListening() {
        var gate = PassThroughGate()
        gate.padListeningBegan()
        let result = decisions(&gate, [(true, true), (true, false), (false, false), (true, false)])
        #expect(result == [false, false, false, true])
    }

    /// 自分で読み取っている間 (iPad から音声入力中) に読み取られなくなっても、音声入力が終わるまでは区切りにしない。
    @Test func readingStopWhileListeningDoesNotRelease() {
        var gate = PassThroughGate()
        gate.padListeningBegan()
        let result = decisions(&gate, [(false, true), (true, false)])
        #expect(result == [false, false])
    }
}
