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

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
