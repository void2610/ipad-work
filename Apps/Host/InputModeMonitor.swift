import Carbon
import Foundation
import PadBridgeKit

/// Mac の文字入力が英数とかなのどちらかを読み、変わるたびに知らせる。メインスレッドで使う。
final class InputModeMonitor: NSObject {
    private let onChange: @Sendable (MacInputMode) -> Void

    init(onChange: @escaping @Sendable (MacInputMode) -> Void) {
        self.onChange = onChange
    }

    func start() {
        // 分散通知は既定では、アプリが前面にない間は前面に来るまで止められる。メニューバーの常駐アプリはほとんど前面に来ないので、すぐ届けさせる
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        onChange(Self.current())
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func inputSourceChanged() {
        onChange(Self.current())
    }

    static func current() -> MacInputMode {
        mode(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    static func mode(of source: TISInputSource) -> MacInputMode {
        let type = property(source, kTISPropertyInputSourceType) as? String
        let modeID = property(source, kTISPropertyInputModeID) as? String
        return MacInputMode(isKeyboardLayout: type == (kTISTypeKeyboardLayout as String), inputModeID: modeID)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
