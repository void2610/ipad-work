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
        view.onPaste = { [weak session] text in session?.send(.insertText(text)) }
        view.send = { [weak session] message in session?.send(message) }
        let bar = KeyAccessoryBar(session: session)
        bar.pasteTarget = view
        view.accessoryBar = bar
        return view
    }

    func updateUIView(_ view: DirectTypingUIView, context _: Context) {
        // キーボードを閉じるボタンなど、こちら以外の理由で入力先から外れたらボタンの表示を戻す
        view.onResign = { isActive = false }
        // 値はここで読む。後で動く処理の中でだけ読むと SwiftUI が依存を記録せず、切り替えてもこの更新が呼ばれなくなる
        let shouldBeActive = isActive
        // SwiftUI の更新の途中でキーボードを出し入れすると、キーボードの分の余白が戻らないので、更新が終わってから行う
        DispatchQueue.main.async {
            if shouldBeActive, !view.isFirstResponder {
                _ = view.becomeFirstResponder()
            } else if !shouldBeActive, view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }
}

/// ソフトウェアキーボードは、入力先が UITextInput でないと削除キーの長押しを繰り返さない (UIKeyInput だけだと 3 秒押しても 1 回)。
/// 打った内容は手元に持たず Mac へ送るだけなので、キーボードには中身の変わらない文書を見せる。
final class DirectTypingUIView: UIView, UITextInput {
    /// 直接入力中か。画面のタップでキーボードを閉じないよう、画面側が見る。
    static var isTyping = false

    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPaste: ((String) -> Void)?
    var onResign: (() -> Void)?
    var send: ((ControlMessage) -> Void)?
    var accessoryBar: UIView?

    // キーボードに見せる文書。削除キーをいつでも受け付けるよう、カーソルの前に常に文字がある。
    // 英字だとキーボードが単語とみなし、空白 2 回をピリオドに置き換えるなど勝手に書き換えるので、改行だけにする
    private static let document = String(repeating: "\n", count: 400) as NSString
    // iPadOS の日本語キーボードなどが変換中の文字。確定したときにまとめて送る
    private var markedText = ""
    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    var hasText: Bool { true }
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    // 打ったキーを Mac の日本語入力に渡すので、iPad 側では変換しない英字配列にする
    var keyboardType = UIKeyboardType.asciiCapable

    override var inputAccessoryView: UIView? {
        accessoryBar
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    private lazy var shortcutCommands = HardwareKeys.priorityCommands(action: #selector(forwardShortcut(_:)))

    override var keyCommands: [UIKeyCommand]? {
        shortcutCommands
    }

    @objc private func forwardShortcut(_ command: UIKeyCommand) {
        HardwareKeys.forwardShortcut(command, send: send)
    }

    // UITextInput の入力先は iPadOS の 3 本指の編集ジェスチャー (取り消しなど) を受けるが、3 本指は Mac のデスクトップ切り替えに使う
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override func becomeFirstResponder() -> Bool {
        // キーボードの上の取り消し・やり直し・ペーストは使わない。手元の文書は飾りで、そのペーストは iOS がペーストの許可を尋ねる
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            Self.isTyping = true
        }
        return didBecome
    }

    func insertText(_ text: String) {
        markedText = ""
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    // 特殊キーの列のペーストボタンで、iPad でコピーした文字をキーを 1 つずつ打たずに文字のまま Mac の入力欄へ入れる (日本語や記号もそのまま入る)
    override var pasteConfiguration: UIPasteConfiguration? {
        get { UIPasteConfiguration(forAccepting: NSString.self) }
        set {}
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String, !text.isEmpty else { return }
            DispatchQueue.main.async { self?.onPaste?(text) }
        }
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

// MARK: - UITextInput

/// キーボードに見せる文書の上の位置。文書は変わらないので、文字の番号だけを持つ。
private final class DocumentPosition: UITextPosition {
    let index: Int

    init(_ index: Int) {
        self.index = index
    }
}

private final class DocumentRange: UITextRange {
    let range: NSRange

    init(_ range: NSRange) {
        self.range = range
    }

    override var start: UITextPosition { DocumentPosition(range.location) }
    override var end: UITextPosition { DocumentPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

extension DirectTypingUIView {
    var beginningOfDocument: UITextPosition { DocumentPosition(0) }
    var endOfDocument: UITextPosition { DocumentPosition(Self.document.length) }

    var selectedTextRange: UITextRange? {
        get { DocumentRange(NSRange(location: Self.document.length, length: 0)) }
        set {}
    }

    var markedTextRange: UITextRange? {
        markedText.isEmpty ? nil : DocumentRange(NSRange(location: Self.document.length, length: 0))
    }

    func setMarkedText(_ markedText: String?, selectedRange _: NSRange) {
        self.markedText = markedText ?? ""
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        let text = markedText
        markedText = ""
        onText?(text)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? DocumentRange else { return nil }
        return Self.document.substring(with: range.range)
    }

    // 文書は変えず、キーボードからの削除と入力は deleteBackward と insertText で受ける
    func replace(_: UITextRange, withText _: String) {}

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? DocumentPosition, let to = toPosition as? DocumentPosition else { return nil }
        return DocumentRange(NSRange(location: min(from.index, to.index), length: abs(from.index - to.index)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? DocumentPosition else { return nil }
        let index = position.index + offset
        return (0 ... Self.document.length).contains(index) ? DocumentPosition(index) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = (position as? DocumentPosition)?.index ?? 0
        let rhs = (other as? DocumentPosition)?.index ?? 0
        return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? DocumentPosition)?.index ?? 0) - ((from as? DocumentPosition)?.index ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in _: UITextLayoutDirection) -> UITextRange? {
        textRange(from: position, to: position)
    }

    func baseWritingDirection(for _: UITextPosition, in _: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_: NSWritingDirection, for _: UITextRange) {}
    func firstRect(for _: UITextRange) -> CGRect { .zero }
    func caretRect(for _: UITextPosition) -> CGRect { .zero }
    func selectionRects(for _: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to _: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to _: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at _: CGPoint) -> UITextRange? { nil }
}
