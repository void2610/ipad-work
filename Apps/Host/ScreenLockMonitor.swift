import CoreGraphics
import Foundation

/// Mac の画面のロックと解除を知らせる。メインスレッドで使う。
/// ロック中は ScreenCaptureKit の取り込みが止まるか断られ、解除しても取り込みは自分では戻らないと報告されている。
final class ScreenLockMonitor: NSObject {
    private let onChange: @Sendable (_ isLocked: Bool) -> Void

    init(onChange: @escaping @Sendable (_ isLocked: Bool) -> Void) {
        self.onChange = onChange
    }

    /// 今ロックされているか。ロック中だけ、セッションの情報にこのキーが現れる。
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        // 入力ソースの知らせと同じく、メニューバーの常駐アプリが前面にない間も止めずに届けさせる
        center.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func locked() {
        onChange(true)
    }

    @objc private func unlocked() {
        onChange(false)
    }
}
