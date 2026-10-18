import CoreGraphics
import Foundation

/// Mac のディスプレイのロックと解除を通知する。メインスレッドで使う。
/// ロック中は ScreenCaptureKit のキャプチャが停止または拒否され、解除してもキャプチャは自動では復帰しないと報告されている。
final class ScreenLockMonitor: NSObject {
    private let onChange: @Sendable (_ isLocked: Bool) -> Void

    init(onChange: @escaping @Sendable (_ isLocked: Bool) -> Void) {
        self.onChange = onChange
    }

    /// 現在ロックされているか。ロック中だけ、セッション情報にこのキーが現れる。
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        // 入力ソースの通知と同じく、メニューバー常駐アプリが前面にない間も保留せずに配信させる
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
