/// 「PadBridge iPad マイク」に、iPad の声の代わりに Mac の既定の入力の音声を流すかを決める。
/// Typeless にはこのデバイスを選択させているので、iPad から話していない間に読み取られたら Mac のマイクの音声を流す。
public struct PassThroughGate: Sendable {
    // iPad からの音声入力が終わったあと Typeless がまだ読み取っていても、その続きに Mac のマイクの音声を混ぜない。読み取りが一度止まるまで
    private var isReservedForPad = false

    public init() {}

    /// iPad から音声入力を開始した。
    public mutating func padListeningBegan() {
        isReservedForPad = true
    }

    /// `isRead` はほかのアプリがこのデバイスを読み取っているか、`isPadListening` は iPad から音声入力中か。
    public mutating func shouldPassThrough(isRead: Bool, isPadListening: Bool) -> Bool {
        if !isRead, !isPadListening {
            isReservedForPad = false
        }
        return isRead && !isPadListening && !isReservedForPad
    }
}
