import AppKit
import CoreGraphics

/// Mac で動いている Typeless 本体の様子。どのスレッドからでも呼べる。
nonisolated enum TypelessApp {
    static let bundleIdentifier = "now.typeless.desktop"
    private static let keyEvents: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Typeless がショートカットを待ち受けているか。ショートカットは本体のプロセスのキーのイベントタップで見ているので、タップができるまでは押しても届かない。
    static func isListeningForShortcut() -> Bool {
        let processes = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
        guard !processes.isEmpty else { return false }
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return false }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return false }
        return taps.prefix(Int(count)).contains { tap in
            tap.enabled && tap.eventsOfInterest & keyEvents != 0 && processes.contains(pid_t(tap.tappingProcess))
        }
    }
}
