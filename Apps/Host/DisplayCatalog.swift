import AppKit
import CoreGraphics
import PadBridgeKit

/// Mac につながっている画面を読む。
enum DisplayCatalog {
    nonisolated struct Snapshot: Sendable {
        var displays: [RemoteDisplay]
        /// 画面ごとの、メニューバーと Dock を除いた範囲 (画面の座標)。ウィンドウを移す先を決めるのに使う。
        var usableAreas: [UInt32: CGRect]
    }

    /// 映せる画面の一覧。画面の名前と使える範囲は NSScreen からしか読めないので、メインスレッドで呼ぶ。
    static func current() -> Snapshot {
        var names: [CGDirectDisplayID: String] = [:]
        var usableAreas: [UInt32: CGRect] = [:]
        // AppKit の座標は、メインディスプレイの左下が原点で上が正。画面の座標 (左上が原点、下が正) に直す
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[id] = screen.localizedName
                let visible = screen.visibleFrame
                usableAreas[id] = CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
            }
        }
        let displays = RemoteDisplay.list(activeDisplays().map { id in
            RemoteDisplay.Source(
                id: id,
                name: names[id] ?? "",
                bounds: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0,
                isMirror: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            )
        })
        return Snapshot(displays: displays, usableAreas: usableAreas)
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
        return axElement(app, kAXFocusedWindowAttribute).flatMap(frame(of:))
    }

    /// 手前のアプリの手前のウィンドウを、`destination` の画面へ移す。移せたら true。すでにその画面にあれば動かさずに true。
    nonisolated static func moveFrontWindow(to destination: UInt32, usableAreas: [UInt32: CGRect]) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        guard let app = axElement(systemWide, kAXFocusedApplicationAttribute) else { return false }
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = axElement(app, kAXFocusedWindowAttribute) else { return false }
        return move(window, to: destination, usableAreas: usableAreas)
    }

    nonisolated static func move(_ window: AXUIElement, to destination: UInt32, usableAreas: [UInt32: CGRect]) -> Bool {
        guard let frame = frame(of: window), let target = usableAreas[destination] else { return false }
        guard let source = RemoteDisplay.showing(window: frame, displays: usableAreas), source != destination, let sourceArea = usableAreas[source] else {
            return RemoteDisplay.showing(window: frame, displays: usableAreas) == destination
        }
        let moved = RemoteDisplay.moved(window: frame, from: sourceArea, to: target)
        // 先に縮めてから動かす。大きいまま動かすと、移す先に収まらない分を macOS が押し戻す
        var size = frame.size
        if moved.size != frame.size {
            setSize(moved.size, of: window)
            size = self.frame(of: window)?.size ?? frame.size
        }
        // 大きさを変えられないウィンドウもあるので、実際の大きさで移す先に収める
        var origin = CGPoint(
            x: max(target.minX, min(moved.minX, target.maxX - size.width)),
            y: max(target.minY, min(moved.minY, target.maxY - size.height))
        )
        guard let value = AXValueCreate(.cgPoint, &origin), AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success else {
            if size != frame.size {
                setSize(frame.size, of: window)
            }
            return false
        }
        return self.frame(of: window).flatMap { RemoteDisplay.showing(window: $0, displays: usableAreas) } == destination
    }

    private nonisolated static func setSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = axValue(window, kAXPositionAttribute), AXValueGetValue(positionValue, .cgPoint, &position),
              let sizeValue = axValue(window, kAXSizeAttribute), AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private nonisolated static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
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
