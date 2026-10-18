import Foundation

/// Mac 側で、押したままのキーを実際のキーボードと同じくリピートする。合成したキーの押下は macOS がリピートしないため。
public struct KeyRepeat: Sendable {
    /// 現在リピート中のキー。実際のキーボードと同じく、最後に押したキーだけをリピートする。
    public private(set) var key: MacKeyEvent?

    public init() {}

    /// 届いたキーを反映する。リピートするキーが新しく決まったら true を返すので、呼び出し側はリピート開始までの待ち時間から数え直す。
    /// `heldModifiers` は、このキーを反映したあとに押されている修飾キー。
    public mutating func apply(_ event: MacKeyEvent, heldModifiers: KeyModifiers) -> Bool {
        if event.isFlagsChanged {
            // リピートの途中で ⇧ などを押したり離したりしたら、以降のリピートに反映する
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
