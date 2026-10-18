import AppKit
import CoreGraphics
import PadBridgeKit

/// Mac につながっている画面を読む。
enum DisplayCatalog {
    /// 映せる画面の一覧。画面の名前は NSScreen からしか読めないので、メインスレッドで呼ぶ。
    static func current() -> [RemoteDisplay] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[id] = screen.localizedName
            }
        }
        return RemoteDisplay.list(activeDisplays().map { id in
            RemoteDisplay.Source(
                id: id,
                name: names[id] ?? "",
                bounds: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0,
                isMirror: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            )
        })
    }

    /// 選ばれた画面を覚えておくための値。`CGDirectDisplayID` と違い、つなぎ直しても再起動しても同じ画面には同じ値が付く。
    nonisolated static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    nonisolated static func id(ofUUID text: String) -> CGDirectDisplayID? {
        guard let uuid = CFUUIDCreateFromString(nil, text as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        return id == kCGNullDirectDisplay ? nil : id
    }

    /// アプリの手前のウィンドウの位置と大きさ (画面の座標)。アクセシビリティの許可が要り、相手のアプリの応答を待つ。
    nonisolated static func focusedWindowFrame(of pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // 応答しないアプリで待ち続けない
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return frame(of: unsafeDowncast(window, to: AXUIElement.self))
    }

    nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = axValue(window, kAXPositionAttribute), AXValueGetValue(positionValue, .cgPoint, &position),
              let sizeValue = axValue(window, kAXSizeAttribute), AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private nonisolated static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
