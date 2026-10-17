/// 「PadBridge iPad マイク」に、iPad の声の代わりに Mac の既定の入力の音を流すかを決める。
/// Typeless にはこのデバイスを選ばせているので、iPad から話していない間に読まれたら Mac のマイクの音を流す。
public struct PassThroughGate: Sendable {
    // iPad からの聞き取りが終わったあと Typeless がまだ読んでいても、その続きに Mac のマイクの音を混ぜない。読むのが一度止まるまで
    private var isReservedForPad = false

    public init() {}

    /// iPad から聞き取りを始めた。
    public mutating func padListeningBegan() {
        isReservedForPad = true
    }

    /// `isRead` はほかのアプリがこのデバイスを読んでいるか、`isPadListening` は iPad から聞き取っているか。
    public mutating func shouldPassThrough(isRead: Bool, isPadListening: Bool) -> Bool {
        if !isRead, !isPadListening {
            isReservedForPad = false
        }
        return isRead && !isPadListening && !isReservedForPad
    }
}
