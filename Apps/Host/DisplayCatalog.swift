import AppKit
import CoreGraphics
import PadBridgeKit

/// Mac に接続されているディスプレイを読み取る。
enum DisplayCatalog {
    nonisolated struct Snapshot: Sendable {
        var displays: [RemoteDisplay]
        /// ディスプレイごとの、メニューバーと Dock を除いた範囲 (ディスプレイ座標)。ウィンドウの移動先の決定に使う。
        var usableAreas: [UInt32: CGRect]
    }

    /// 表示できるディスプレイの一覧。名前と使用可能範囲は NSScreen からしか取得できないので、メインスレッドで呼ぶ。
    static func current() -> Snapshot {
        var names: [CGDirectDisplayID: String] = [:]
        var usableAreas: [UInt32: CGRect] = [:]
        // AppKit の座標は、メインディスプレイの左下が原点で上が正。ディスプレイ座標 (左上が原点、下が正) に変換する
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

    /// 選択されたディスプレイを保存するための値。`CGDirectDisplayID` と違い、再接続や再起動をしても同じディスプレイには同じ値が付く。
    nonisolated static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    nonisolated static func id(ofUUID text: String) -> CGDirectDisplayID? {
        guard let uuid = CFUUIDCreateFromString(nil, text as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        return id == kCGNullDirectDisplay ? nil : id
    }

    /// アプリの最前面のウィンドウの位置とサイズ (ディスプレイ座標)。アクセシビリティの許可が必要で、相手アプリの応答を待つ。
    nonisolated static func focusedWindowFrame(of pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // 応答しないアプリで待ち続けない。タイムアウトは要素ごとなので、ウィンドウ要素にも設定する
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = axElement(app, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.5)
        return frame(of: window)
    }

    /// 最前面アプリの最前面のウィンドウを、`destination` のディスプレイへ移動する。移動できたら true。すでにそのディスプレイ上にあれば動かさずに true。
    nonisolated static func moveFrontWindow(to destination: UInt32, usableAreas: [UInt32: CGRect]) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        guard let app = axElement(systemWide, kAXFocusedApplicationAttribute) else { return false }
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = axElement(app, kAXFocusedWindowAttribute) else { return false }
        AXUIElementSetMessagingTimeout(window, 0.5)
        return move(window, to: destination, usableAreas: usableAreas)
    }

    nonisolated static func move(_ window: AXUIElement, to destination: UInt32, usableAreas: [UInt32: CGRect]) -> Bool {
        guard let frame = frame(of: window), let target = usableAreas[destination] else { return false }
        let source = RemoteDisplay.showing(window: frame, displays: usableAreas)
        guard source != destination else { return true }
        // どのディスプレイとも重ならない (取り外したディスプレイに残った) ウィンドウは、移動先のディスプレイ内に寄せて回収する
        let sourceArea = source.flatMap { usableAreas[$0] } ?? target
        let moved = RemoteDisplay.moved(window: frame, from: sourceArea, to: target)
        // 先に縮小してから移動する。大きいまま移動すると、移動先に収まらない分を macOS が押し戻す
        var size = frame.size
        if moved.size != frame.size {
            setSize(moved.size, of: window)
            size = self.frame(of: window)?.size ?? frame.size
        }
        // サイズを変更できないウィンドウもあるので、実際のサイズで移動先に収める
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

    /// Dock があるディスプレイ。ウィンドウサーバーが持つ Dock の範囲と、その範囲に最も合うディスプレイを、yabai と同じ非公開関数で取得する。
    /// 非表示の Dock の範囲は高さ 0 でディスプレイの端に載るため、範囲の重なりでは判定できない。取得できなければ nil。
    nonisolated static func dockDisplay() -> CGDirectDisplayID? {
        guard let skyLight = SkyLight.shared else { return nil }
        let connection = skyLight.mainConnection()
        var rect = CGRect.zero
        var reason: Int32 = 0
        guard skyLight.dockRect(connection, &rect, &reason) == 0,
              let uuid = skyLight.bestDisplay(connection, rect)?.takeRetainedValue()
        else { return nil }
        return id(ofUUID: uuid as String)
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

/// Dock の位置を取得するための SkyLight の非公開関数。リンクせずに探索し、見つからない macOS では使わない。
private nonisolated struct SkyLight: @unchecked Sendable {
    let mainConnection: @convention(c) () -> Int32
    let dockRect: @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32
    let bestDisplay: @convention(c) (Int32, CGRect) -> Unmanaged<CFString>?

    static let shared: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let dockRect = dlsym(handle, "SLSGetDockRectWithReason"),
              let bestDisplay = dlsym(handle, "SLSCopyBestManagedDisplayForRect")
        else { return nil }
        return SkyLight(
            mainConnection: unsafeBitCast(mainConnection, to: (@convention(c) () -> Int32).self),
            dockRect: unsafeBitCast(dockRect, to: (@convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32).self),
            bestDisplay: unsafeBitCast(bestDisplay, to: (@convention(c) (Int32, CGRect) -> Unmanaged<CFString>?).self)
        )
    }()
}
