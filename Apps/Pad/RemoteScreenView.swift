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
        view.shownRegion = session.videoRegion
    }
}

/// Mac の画面を映し、指・ポインタ・ハードウェアキーボードの操作を Mac の操作に変換する。対応表は README を参照。
final class RemoteScreenUIView: UIView {
    var send: ((ControlMessage) -> Void)?
    var sendPointer: (([ControlMessage]) -> Void)?
    var onThreeFingerSwipe: ((TouchInterpreter.SwipeDirection) -> Void)?
    var onBottomEdgeSwipe: (() -> Void)?
    var onRegionRequest: ((VideoRegion) -> Void)?
    /// 届いている映像に写っている Mac の画面の範囲。拡大中は見えている範囲だけが高い解像度で届く。
    var shownRegion = VideoRegion.full {
        didSet {
            if shownRegion != oldValue { setNeedsLayout() }
        }
    }
    private var regionRequestTimer: Timer?
    var videoSize = CGSize.zero

    private let displayLayer: AVSampleBufferDisplayLayer
    // ビューの座標での、画面の下端に付いたキーボードの上端。キーボードがなければ無限大
    private var keyboardTop = CGFloat.infinity
    private var interpreter = TouchInterpreter()
    private var zoom = ScreenZoom()
    private var longPressTimer: DispatchWorkItem?
    // トラックパッドやマウスのクリックは、指と違って押した瞬間に押下として送る。押したボタンを指ごとに覚えておく
    private var pointerButtons: [ObjectIdentifier: MouseButton] = [:]
    private var lastScrollTranslation = CGPoint.zero
    private var momentum: ScrollMomentum?
    private var momentumLink: CADisplayLink?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        // 拡大した映像がビューの外にはみ出して、操作パネルの下などに描かれないようにする
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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 届いている映像は shownRegion の範囲だけなので、画面全体の中でその範囲が占める位置に置く
        displayLayer.frame = shownRegion.rect(in: videoRect)
        CATransaction.commit()
        // キーボードが出ている間は、その上端は画面の下端ではないので、下端からの払いを受けない
        interpreter.bottomEdge = isKeyboardShown ? .infinity : bounds.maxY
    }

    // MARK: - キーボード

    // キーボードの分は、SwiftUI の余白や keyboardLayoutGuide ではなく、キーボードの通知が知らせる位置から決める。
    // 特殊キーの列を付けた入力欄をプログラムから外すと、どちらも列の高さ分を残したまま戻らない (通知は正しく画面外を知らせる)
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window else { return }
        let frame = window.screen.coordinateSpace.convert(end, to: self)
        // 画面の下端に付いていない (フローティングの) キーボードは、映像に重ねるだけにする
        keyboardTop = frame.minY < bounds.maxY && frame.maxY >= bounds.maxY - 1 ? frame.minY : .infinity
        setNeedsLayout()
    }

    @objc private func keyboardWillHide(_: Notification) {
        keyboardTop = .infinity
        setNeedsLayout()
    }

    private var isKeyboardShown: Bool {
        keyboardTop < bounds.maxY - 1
    }

    /// Mac の画面を映す範囲。キーボードが出ている間は、その上までに縮める。
    private var screenArea: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, min(keyboardTop, bounds.maxY) - bounds.minY))
    }

    // MARK: - 座標

    /// 等倍のときに映像を置く位置。
    private var fittedRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return screenArea }
        return AVMakeRect(aspectRatio: videoSize, insideRect: screenArea)
    }

    /// 拡大を反映した、映像を置く位置。タッチの位置もここを基準に Mac の座標へ直す。
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
        // 慣性で流れている途中に触れたら、iPad と同じくその場で止める
        stopMomentum()
        for touch in touches {
            let location = touch.location(in: self)
            // Apple Pencil は Sidecar と同じく、触れたところを押してそのまま動かすとドラッグにする (指で払うのはスクロールのまま)
            if touch.type == .indirectPointer || touch.type == .pencil {
                let button: MouseButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
                pointerButtons[ObjectIdentifier(touch)] = button
                sendPointer?([.mouseMove(normalized(location)), .mouseButton(button, isDown: true, at: normalized(location))])
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
            } else {
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
            } else {
                perform(interpreter.ended(touch: Self.id(of: touch), at: location, time: touch.timestamp))
            }
        }
        scheduleLongPressIfNeeded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            if let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) {
                sendPointer?([.mouseButton(button, isDown: false, at: normalized(touch.location(in: self)))])
            } else {
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
            case let .scrollEnded(velocityX, velocityY):
                startMomentum(velocityX: velocityX, velocityY: velocityY)
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

    /// 拡大が落ち着いたら、見えている範囲を Mac に頼む。動かしている間に何度も頼まないよう、少し待つ。
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

    private func startMomentum(velocityX: CGFloat, velocityY: CGFloat) {
        let momentum = ScrollMomentum(velocityX: velocityX, velocityY: velocityY)
        guard !momentum.isFinished else { return }
        self.momentum = momentum
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let rect = videoRect
        guard var momentum, rect.width > 0, rect.height > 0 else {
            stopMomentum()
            return
        }
        let delta = momentum.step(interval: link.targetTimestamp - link.timestamp)
        self.momentum = momentum
        sendPointer?([.scroll(dx: delta.dx / rect.width, dy: delta.dy / rect.height)])
        if momentum.isFinished {
            stopMomentum()
        }
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentum = nil
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
        if !forward(presses, isDown: true) {
            super.pressesBegan(presses, with: event)
        }
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
