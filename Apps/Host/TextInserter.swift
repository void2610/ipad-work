import ApplicationServices
import CoreGraphics
import Foundation

/// iPad で確定した文字列を、Mac の入力カーソル位置に挿入する。
/// クリップボードを経由すると、ユーザーのクリップボードやクリップボード履歴アプリを汚すため使わない。
nonisolated enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if insertViaAccessibility(text) { return }
        typeViaUnicodeEvents(text)
    }

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else {
            return false
        }
        let before = value(of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        // 成功を返しても実際には反映しないアプリ (Electron 製など) があるため、値が変わったかで確かめる
        guard let before, let after = value(of: element) else { return true }
        return before != after
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func typeViaUnicodeEvents(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            // 1 イベントに載せられる文字数には上限があるため、小分けにして送る
            var end = min(start + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[start ..< end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cghidEventTap)
            }
            start = end
        }
    }
}
