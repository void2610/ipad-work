import AVFoundation
import PadBridgeKit
import SwiftUI
import UIKit

struct RemoteScreenView: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context _: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView(displayLayer: session.renderer.displayLayer)
        view.send = { [weak session] message in session?.send(message) }
        view.sendPointer = { [weak session] messages in session?.sendPointer(messages) }
        view.onThreeFingerSwipe = { [weak session] direction in session?.swipeDesktop(direction) }
        view.onBottomEdgeSwipe = { [weak session] in session?.showDock() }
        view.onRegionRequest = { [weak session] region in session?.requestVideoRegion(region) }
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context _: Context) {
        view.videoSize = session.videoSize
        view.isVideoShown = session.isVideoShown
        view.shownRegion = session.videoRegion
        view.displayID = session.shownDisplayID
    }
}

/// Mac のディスプレイを表示し、指・ポインタ・ハードウェアキーボードの操作を Mac の操作に変換する。対応表は README を参照。
final class RemoteScreenUIView: UIView {
    var send: ((ControlMessage) -> Void)?
    var sendPointer: (([ControlMessage]) -> Void)?
    var onThreeFingerSwipe: ((TouchInterpreter.SwipeDirection) -> Void)?
    var onBottomEdgeSwipe: (() -> Void)?
    var onRegionRequest: ((VideoRegion) -> Void)?
    /// 受信している映像に写っている Mac のディスプレイの範囲。拡大中は表示範囲だけが高解像度で届く。
    var shownRegion = VideoRegion.full {
        didSet {
            if shownRegion != oldValue { setNeedsLayout() }
        }
    }
    private var regionRequestTimer: Timer?
    private var lastScreenArea = CGRect.null
    var videoSize = CGSize.zero {
        // ディスプレイを切り替えると、切り替え通知で一度配置し直したあとに新しいディスプレイのサイズが届く。そのときも配置し直さないと、映像が前のディスプレイの縦横比の枠に縮んで描かれ、タッチ位置とずれる
        didSet {
            if videoSize != oldValue { setNeedsLayout() }
        }
    }
    /// 映像を表示しているか。表示していない間は Mac のポインタも見えないので、iPad のポインタを隠さない。
    var isVideoShown = false {
        didSet {
            if isVideoShown != oldValue { pointerInteraction?.invalidate() }
        }
    }
    /// 表示している Mac のディスプレイ。別のディスプレイに切り替わったら、拡大を戻す。
    var displayID: UInt32? {
        didSet {
            guard oldValue != nil, displayID != oldValue else { return }
            regionRequestTimer?.invalidate()
            zoom = ScreenZoom()
            setNeedsLayout()
            // 切り替え前に待機していた拡大範囲の要求が先に送られていても、全体に戻させる
            onRegionRequest?(.full)
        }
    }

    private let displayLayer: AVSampleBufferDisplayLayer
    private let emptyInputView = UIView(frame: .zero)
    // ビュー座標での、画面下端に付いたキーボードの上端。キーボードがなければ無限大
    private var keyboardTop = CGFloat.infinity
    private var interpreter = TouchInterpreter()
    private var zoom = ScreenZoom()
    private var pointerInteraction: UIPointerInteraction?
    private var longPressTimer: DispatchWorkItem?
    // トラックパッドやマウスのクリックは、指と違って押した瞬間に押下として送る。押したボタンを指ごとに保持しておく
    private var pointerButtons: [ObjectIdentifier: MouseButton] = [:]
    // ペンやマウスのボタンを押している間に触れた指や手のひら。押したままのボタンに、指の位置への移動やクリックが割り込まないよう、離すまで無視する
    private var ignoredTouches: Set<ObjectIdentifier> = []
    private var lastScrollTranslation = CGPoint.zero

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        // 拡大した映像がビューの外にはみ出して、操作パネルの下などに描画されないようにする
        clipsToBounds = true
        // 既定の false のままだと 2 本目の指が届かず、2 本指のスクロールが成立しない
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        isAccessibilityElement = true
        accessibilityLabel = "Mac の画面"
        // VoiceOver 中も、指の操作をそのまま Mac に届ける
        accessibilityTraits = .allowsDirectInteraction
        installGestureRecognizers()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(directTypingDidEnd), name: DirectTypingUIView.didEndTyping, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    private lazy var shortcutCommands = HardwareKeys.priorityCommands(action: #selector(forwardShortcut(_:)))

    override var keyCommands: [UIKeyCommand]? {
        shortcutCommands
    }

    @objc private func forwardShortcut(_ command: UIKeyCommand) {
        // 一覧を表示している間にキーを渡すと、ここに届く (押したキーと同様に、Mac へは送らない)
        guard !isCovered else { return }
        HardwareKeys.forwardShortcut(command, send: send)
    }

    // テキスト入力を持たないビューでも、ファーストレスポンダのまま「…」のメニューを開くと iPadOS がソフトウェアキーボードを表示してメニューを隠すので、空の入力ビューに置き換える
    override var inputView: UIView? {
        emptyInputView
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 拡大中にキーボードの表示・非表示や回転で表示範囲が変わったら、表示範囲を要求し直す。前の範囲のままだと縁が黒くなる
        if screenArea != lastScreenArea {
            lastScreenArea = screenArea
            if zoom.isZoomed { scheduleRegionRequest() }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 受信している映像は shownRegion の範囲だけなので、ディスプレイ全体の中でその範囲が占める位置に配置する
        displayLayer.frame = shownRegion.rect(in: videoRect)
        CATransaction.commit()
        // キーボードが表示されている間は、その上端は画面下端ではないので、下端からのスワイプを受けない
        interpreter.bottomEdge = isKeyboardShown ? .infinity : bounds.maxY
        // 拡大や回転で Mac のディスプレイの範囲が変わったので、ポインタを隠す範囲を再計算させる
        pointerInteraction?.invalidate()
    }

    // MARK: - キーボード

    // キーボード分は、SwiftUI の余白や keyboardLayoutGuide ではなく、キーボードの通知が伝える位置から決める。
    // キーボード上部のバーを付けた入力欄をプログラムから外すと、どちらもバーの高さ分を残したまま戻らない (通知は正しく画面外を伝える)
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window else { return }
        let frame = window.screen.coordinateSpace.convert(end, to: self)
        // 画面下端に付いていない (フローティングの) キーボードは、映像に重ねるだけにする
        keyboardTop = frame.minY < bounds.maxY && frame.maxY >= bounds.maxY - 1 ? frame.minY : .infinity
        setNeedsLayout()
    }

    // キーボードを閉じたあと、画面に触れなくてもハードウェアキーボードのキーを Mac に届ける (ファーストレスポンダがないとキーは破棄される)
    @objc private func directTypingDidEnd(_: Notification) {
        guard window != nil, !isCovered, !isFirstResponder, !DirectTypingUIView.isTyping else { return }
        becomeFirstResponder()
    }

    @objc private func keyboardWillHide(_: Notification) {
        keyboardTop = .infinity
        setNeedsLayout()
    }

    private var isKeyboardShown: Bool {
        keyboardTop < bounds.maxY - 1
    }

    /// Mac のディスプレイを表示する範囲。キーボードが表示されている間は、その上までに縮める。
    private var screenArea: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, min(keyboardTop, bounds.maxY) - bounds.minY))
    }

    // MARK: - 座標

    /// 等倍のときに映像を配置する位置。
    private var fittedRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return screenArea }
        return AVMakeRect(aspectRatio: videoSize, insideRect: screenArea)
    }

    /// 拡大を反映した、映像の配置位置。タッチ位置もここを基準に Mac の座標へ変換する。
    private var videoRect: CGRect {
        zoom.rect(fitted: fittedRect, in: screenArea)
    }

    private func normalized(_ location: CGPoint) -> NormalizedPoint {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
    }

    // MARK: - タッチ

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 入力欄を触ったあとでも、画面に触れればハードウェアキーボードの入力を Mac に戻す。直接入力中はキーボードを閉じないよう奪わない
        if !isFirstResponder, !DirectTypingUIView.isTyping {
            becomeFirstResponder()
        }
        for touch in touches {
            let location = touch.location(in: self)
            // Apple Pencil は Sidecar と同様に、触れた位置を押してそのまま動かすとドラッグにする (指のスワイプはスクロールのまま)
            if touch.type == .indirectPointer || touch.type == .pencil {
                let button: MouseButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
                pointerButtons[ObjectIdentifier(touch)] = button
                sendPointer?([.mouseMove(normalized(location)), .mouseButton(button, isDown: true, at: normalized(location))])
            } else if !pointerButtons.isEmpty {
                ignoredTouches.insert(ObjectIdentifier(touch))
            } else {
                perform(interpreter.began(touch: Self.id(of: touch), at: location, time: touch.timestamp))
            }
        }
        scheduleLongPressIfNeeded()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            if pointerButtons[ObjectIdentifier(touch)] != nil {
                sendPointer?([.mouseMove(normalized(location))])
            } else if !ignoredTouches.contains(ObjectIdentifier(touch)) {
                perform(interpreter.moved(touch: Self.id(of: touch), to: location, time: touch.timestamp))
            }
        }
        scheduleLongPressIfNeeded()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            if let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) {
                sendPointer?([.mouseButton(button, isDown: false, at: normalized(location))])
            } else if ignoredTouches.remove(ObjectIdentifier(touch)) == nil {
                perform(interpreter.ended(touch: Self.id(of: touch), at: location, time: touch.timestamp))
            }
        }
        scheduleLongPressIfNeeded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            if let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) {
                sendPointer?([.mouseButton(button, isDown: false, at: normalized(touch.location(in: self)))])
            } else if ignoredTouches.remove(ObjectIdentifier(touch)) == nil {
                perform(interpreter.cancelled(touch: Self.id(of: touch)))
            }
        }
        scheduleLongPressIfNeeded()
    }

    private func scheduleLongPressIfNeeded() {
        guard interpreter.isWaitingForLongPress else {
            longPressTimer?.cancel()
            longPressTimer = nil
            return
        }
        guard longPressTimer == nil else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            longPressTimer = nil
            perform(interpreter.longPressTimerFired())
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchInterpreter.longPressDuration, execute: timer)
    }

    private func perform(_ actions: [TouchInterpreter.Action]) {
        let rect = videoRect
        var pointerMessages: [ControlMessage] = []
        defer {
            if !pointerMessages.isEmpty {
                sendPointer?(pointerMessages)
            }
        }
        for action in actions {
            switch action {
            case let .move(point):
                pointerMessages.append(.mouseMove(normalized(point)))
            case let .press(button, isDown, point):
                pointerMessages.append(.mouseButton(button, isDown: isDown, at: normalized(point)))
            case let .scroll(dx, dy):
                guard rect.width > 0, rect.height > 0 else { continue }
                pointerMessages.append(.scroll(dx: dx / rect.width, dy: dy / rect.height))
            case .scrollEnded:
                // 指を離したら止める。慣性スクロールさせると、映像の遅延の分だけ表示位置より先まで流れ、思った位置で止められない
                break
            case .longPressRecognized:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case let .threeFingerSwipe(direction):
                onThreeFingerSwipe?(direction)
            case .bottomEdgeSwipe:
                onBottomEdgeSwipe?()
            case let .zoom(scale, center, translation):
                zoom.apply(scale: scale, center: center, translation: translation, fitted: fittedRect, area: screenArea)
                setNeedsLayout()
                scheduleRegionRequest()
            }
        }
    }

    /// 拡大が落ち着いたら、表示範囲を Mac に要求する。動かしている間に何度も要求しないよう、少し待つ。
    private func scheduleRegionRequest() {
        regionRequestTimer?.invalidate()
        regionRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let region = self.zoom.isZoomed ? VideoRegion.visible(zoomed: self.videoRect, area: self.screenArea) : .full
                self.onRegionRequest?(region)
            }
        }
    }

    private static func id(of touch: UITouch) -> Int {
        ObjectIdentifier(touch).hashValue
    }

    // MARK: - ポインタのホバーとスクロール

    private func installGestureRecognizers() {
        // トラックパッドやマウスホイールのスクロールだけを受け、指のタッチは受けない
        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll))
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.allowedTouchTypes = []
        addGestureRecognizer(pointerScroll)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))
        let pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
        self.pointerInteraction = pointerInteraction
    }

    @objc private func handlePointerScroll(_ recognizer: UIPanGestureRecognizer) {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        switch recognizer.state {
        case .began:
            lastScrollTranslation = .zero
            sendPointer?([.mouseMove(normalized(recognizer.location(in: self)))])
        case .changed:
            let translation = recognizer.translation(in: self)
            let dx = translation.x - lastScrollTranslation.x
            let dy = translation.y - lastScrollTranslation.y
            lastScrollTranslation = translation
            sendPointer?([.scroll(dx: dx / rect.width, dy: dy / rect.height)])
        default:
            break
        }
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        sendPointer?([.mouseMove(normalized(recognizer.location(in: self)))])
    }

    // MARK: - ハードウェアキーボード

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 操作の一覧などを前面に表示している間は、ファーストレスポンダのままでもキーを Mac へ送らない (離したキーは、押したまま表示したときに残らないよう送る)
        if isCovered || !forward(presses, isDown: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    private var isCovered: Bool {
        window?.rootViewController?.presentedViewController != nil
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, isDown: false) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, isDown: false) {
            super.pressesCancelled(presses, with: event)
        }
    }

    private func forward(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        HardwareKeys.forward(presses, isDown: isDown, send: send)
    }
}

/// iPad のハードウェアキーボードのキーを、そのまま Mac のキーとして送る。
enum HardwareKeys {
    private static let shortcutInputs = "abcdefghijklmnopqrstuvwxyz0123456789,./;'[]-=`\\".map(String.init)
    private static let shortcutModifiers: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .control]]

    /// ⌘ との組み合わせを、iPadOS より先に受け取ると宣言するショートカット。
    /// 宣言しないと ⌘F・⌘B・⌘I・⌘E などは iPadOS のメニューや入力機構に取られ、押したキーが届かない。宣言すると押したキーがそのまま presses に届くので、
    /// `action` はそうならなかったときのフォールバックになる。
    static func priorityCommands(action: Selector) -> [UIKeyCommand] {
        shortcutModifiers.flatMap { modifiers in
            shortcutInputs.map { input in
                let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }

    /// 宣言したショートカットの動作として呼ばれたときに、そのキーを Mac へ送る。修飾キーは押したときに presses で送っている。
    static func forwardShortcut(_ command: UIKeyCommand, send: ((ControlMessage) -> Void)?) {
        guard let input = command.input else { return }
        RemoteKeys.shortcut(input, modifiers: modifiers(from: command.modifierFlags)).forEach { send?($0) }
    }

    static func forward(_ presses: Set<UIPress>, isDown: Bool, send: ((ControlMessage) -> Void)?) -> Bool {
        let keys = presses.compactMap(\.key)
        for key in keys {
            send?(.key(usage: key.keyCode.rawValue, isDown: isDown, modifiers: modifiers(from: key.modifierFlags)))
        }
        return !keys.isEmpty
    }

    private static func modifiers(from flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

// Mac のディスプレイ上では iPad のポインタを隠し、映像に描かれた Mac のポインタだけを見せる。両方だと二重に見え、形 (I ビームなど) は Mac 側にしかない
extension RemoteScreenUIView: UIPointerInteractionDelegate {
    func pointerInteraction(_: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion _: UIPointerRegion) -> UIPointerRegion? {
        // 映像が届く前は映像の範囲がディスプレイ全体になるが、Mac のポインタはまだ見えない
        guard isVideoShown else { return nil }
        // 上下や左右の黒い帯と、拡大した映像がキーボードの下に回り込んだところでは、iPad のポインタを表示したままにする
        let screen = videoRect.intersection(screenArea)
        return screen.contains(request.location) ? UIPointerRegion(rect: screen) : nil
    }

    func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}
