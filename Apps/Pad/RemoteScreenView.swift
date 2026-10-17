import AVFoundation
import PadBridgeKit
import SwiftUI
import UIKit

struct RemoteScreenView: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context _: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView(displayLayer: session.renderer.displayLayer)
        view.send = { [weak session] message in session?.send(message) }
        view.onThreeFingerSwipe = { [weak session] direction in session?.pressControlArrow(usage: direction.controlArrowUsage) }
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context _: Context) {
        view.videoSize = session.videoSize
    }
}

/// Mac の画面を映し、指・ポインタ・ハードウェアキーボードの操作を Mac の操作に変換する。対応表は README を参照。
final class RemoteScreenUIView: UIView {
    var send: ((ControlMessage) -> Void)?
    var onThreeFingerSwipe: ((TouchInterpreter.SwipeDirection) -> Void)?
    var videoSize = CGSize.zero

    private let displayLayer: AVSampleBufferDisplayLayer
    private var interpreter = TouchInterpreter()
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
        // 既定の false のままだと 2 本目の指が届かず、2 本指のスクロールが成立しない
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        isAccessibilityElement = true
        accessibilityLabel = "Mac の画面"
        accessibilityIdentifier = "remoteScreen"
        // VoiceOver 中も、指の操作をそのまま Mac に届ける
        accessibilityTraits = .allowsDirectInteraction
        installGestureRecognizers()
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
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 座標

    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    private func normalized(_ location: CGPoint) -> NormalizedPoint {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
    }

    // MARK: - タッチ

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 入力欄を触ったあとでも、画面に触れればハードウェアキーボードの入力を Mac に戻す
        if !isFirstResponder {
            becomeFirstResponder()
        }
        // 慣性で流れている途中に触れたら、iPad と同じくその場で止める
        stopMomentum()
        for touch in touches {
            let location = touch.location(in: self)
            if touch.type == .indirectPointer {
                let button: MouseButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
                pointerButtons[ObjectIdentifier(touch)] = button
                send?(.mouseMove(normalized(location)))
                send?(.mouseButton(button, isDown: true, at: normalized(location)))
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
                send?(.mouseMove(normalized(location)))
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
                send?(.mouseButton(button, isDown: false, at: normalized(location)))
            } else {
                perform(interpreter.ended(touch: Self.id(of: touch), at: location, time: touch.timestamp))
            }
        }
        scheduleLongPressIfNeeded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            if let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) {
                send?(.mouseButton(button, isDown: false, at: normalized(touch.location(in: self))))
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
        for action in actions {
            switch action {
            case let .move(point):
                send?(.mouseMove(normalized(point)))
            case let .press(button, isDown, point):
                send?(.mouseButton(button, isDown: isDown, at: normalized(point)))
            case let .scroll(dx, dy):
                guard rect.width > 0, rect.height > 0 else { continue }
                send?(.scroll(dx: dx / rect.width, dy: dy / rect.height))
            case let .scrollEnded(velocityX, velocityY):
                startMomentum(velocityX: velocityX, velocityY: velocityY)
            case .longPressRecognized:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case let .threeFingerSwipe(direction):
                onThreeFingerSwipe?(direction)
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
        send?(.scroll(dx: delta.dx / rect.width, dy: delta.dy / rect.height))
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
            send?(.mouseMove(normalized(recognizer.location(in: self))))
        case .changed:
            let translation = recognizer.translation(in: self)
            let dx = translation.x - lastScrollTranslation.x
            let dy = translation.y - lastScrollTranslation.y
            lastScrollTranslation = translation
            send?(.scroll(dx: dx / rect.width, dy: dy / rect.height))
        default:
            break
        }
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        send?(.mouseMove(normalized(recognizer.location(in: self))))
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
        let keys = presses.compactMap(\.key)
        for key in keys {
            send?(.key(usage: key.keyCode.rawValue, isDown: isDown, modifiers: Self.modifiers(from: key.modifierFlags)))
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
