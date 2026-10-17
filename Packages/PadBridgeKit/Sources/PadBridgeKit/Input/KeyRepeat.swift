import Foundation

/// Mac 側で、押したままのキーを実際のキーボードと同じく繰り返す。合成したキーの押下は macOS が繰り返してくれないため。
public struct KeyRepeat: Sendable {
    /// 今繰り返しているキー。実際のキーボードと同じく、最後に押したキーだけを繰り返す。
    public private(set) var key: MacKeyEvent?

    public init() {}

    /// 届いたキーを反映する。繰り返すキーが新しく決まったら true を返すので、呼び出し側は繰り返し始めるまでの待ち時間から数え直す。
    /// `heldModifiers` は、このキーを反映したあとに押されている修飾キー。
    public mutating func apply(_ event: MacKeyEvent, heldModifiers: KeyModifiers) -> Bool {
        if event.isFlagsChanged {
            // 繰り返しの途中で ⇧ などを押し離ししたら、そのあとの繰り返しに反映する
            if let keyCode = key?.keyCode {
                key?.flags = KeyboardMapping.eventFlags(modifiers: heldModifiers, macVirtualKeyCode: keyCode)
            }
            return false
        }
        if event.isDown {
            key = event
            return true
        }
        if key?.keyCode == event.keyCode {
            key = nil
        }
        return false
    }

    public mutating func stop() {
        key = nil
    }
}
