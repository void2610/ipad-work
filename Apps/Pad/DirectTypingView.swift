import PadBridgeKit
import SwiftUI
import UIKit

/// ソフトウェアキーボードで打ったキーを、そのまま Mac へ送る見えない入力先。日本語は Mac 側の日本語入力で変換する。
struct DirectTypingField: UIViewRepresentable {
    let session: HostSession
    @Binding var isActive: Bool

    func makeUIView(context _: Context) -> DirectTypingUIView {
        let view = DirectTypingUIView()
        view.onText = { [weak session] text in session?.typeText(text) }
        view.onDeleteBackward = { [weak session] in session?.tapKey(usage: HIDUsage.backspace) }
        view.send = { [weak session] message in session?.send(message) }
        view.accessoryBar = KeyAccessoryBar(session: session)
        return view
    }

    func updateUIView(_ view: DirectTypingUIView, context _: Context) {
        // キーボードを閉じるボタンなど、こちら以外の理由で入力先から外れたらボタンの表示を戻す
        view.onResign = { isActive = false }
        // SwiftUI の更新の途中でキーボードを出し入れすると、キーボードの分の余白が戻らないので、更新が終わってから行う
        DispatchQueue.main.async {
            if isActive, !view.isFirstResponder {
                _ = view.becomeFirstResponder()
            } else if !isActive, view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }
}

final class DirectTypingUIView: UIView, UIKeyInput {
    /// 直接入力中か。画面のタップでキーボードを閉じないよう、画面側が見る。
    static var isTyping = false

    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onResign: (() -> Void)?
    var send: ((ControlMessage) -> Void)?
    var accessoryBar: UIView?

    // 打った内容を手元に持たないので、削除キーをいつでも受け付けるよう常に「文字あり」とする
    var hasText: Bool { true }
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    // 打ったキーを Mac の日本語入力に渡すので、iPad 側では変換しない英字配列にする
    var keyboardType = UIKeyboardType.asciiCapable

    override var inputAccessoryView: UIView? {
        accessoryBar
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            Self.isTyping = true
        }
        return didBecome
    }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            Self.isTyping = false
            let onResign = onResign
            DispatchQueue.main.async { onResign?() }
        }
        return didResign
    }

    // ハードウェアキーボードのキーは文字にせず、修飾キーや矢印も含めてそのまま Mac へ送る
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !HardwareKeys.forward(presses, isDown: true, send: send) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !HardwareKeys.forward(presses, isDown: false, send: send) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !HardwareKeys.forward(presses, isDown: false, send: send) {
            super.pressesCancelled(presses, with: event)
        }
    }
}
