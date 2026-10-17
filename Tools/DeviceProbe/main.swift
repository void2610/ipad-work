import AppKit

// 実機の iPad から Typeless で話したとき、その文字が Mac の入力欄に届くかを確かめる。
// Typeless の結果が他のアプリに入らないよう、確かめている間は自分の入力欄を最前面に置く。

@MainActor
final class Probe {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))

    init() {
        window.title = "PadBridge Typeless の確認"
        window.level = .floating
        window.contentView = textView
        window.center()
    }

    func run(timeout: TimeInterval) async -> Int32 {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate()
        defer { window.close() }

        let deadline = Date.now.addingTimeInterval(timeout)
        var wasShowing = false
        while Date.now < deadline {
            let isShowing = Self.typelessIsShowing()
            if isShowing != wasShowing {
                print(isShowing ? "Typeless の表示が出た" : "Typeless の表示が消えた")
                wasShowing = isShowing
            }
            if !textView.string.isEmpty {
                // 続きの文字が届ききるまで少し待つ
                try? await Task.sleep(for: .seconds(2))
                print("入力欄に届いた文字: \(textView.string)")
                return 0
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("\(Int(timeout)) 秒待っても文字が届かない")
        return 1
    }

    /// 待機中も 1x1 の窓が 1 つあるので、それより大きい表示だけを見る。
    private static func typelessIsShowing() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerName as String] as? String)?.contains("Typeless") == true,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return (bounds["Width"] ?? 0) > 10 && (bounds["Height"] ?? 0) > 10
        }
    }
}

let app = NSApplication.shared
Task { @MainActor in
    exit(await Probe().run(timeout: 120))
}
app.run()
