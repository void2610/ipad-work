import AVFoundation
import PadBridgeKit
import SwiftUI
import UIKit

struct RemoteScreenView: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context _: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView(displayLayer: session.renderer.displayLayer)
        view.send = { [weak session] message in session?.send(message) }
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context _: Context) {
        view.videoSize = session.videoSize
    }
}

/// Mac の画面を映し、指・ポインタ・ハードウェアキーボードの操作を Mac の操作に変換する。対応表は README を参照。
final class RemoteScreenUIView: UIView {
    var send: ((ControlMessage) -> Void)?
    var videoSize = CGSize.zero

    private let displayLayer: AVSampleBufferDisplayLayer
    private var lastScrollTranslation = CGPoint.zero

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
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

    // MARK: - ジェスチャー

    private func installGestureRecognizers() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick))
        secondaryClick.buttonMaskRequired = .secondary

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.5

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.maximumNumberOfTouches = 1

        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2

        // トラックパッドやマウスホイールのスクロールだけを受け、指のタッチは受けない
        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.allowedTouchTypes = []

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))

        for recognizer in [tap, secondaryClick, twoFingerTap, longPress, drag, twoFingerScroll, pointerScroll, hover] {
            addGestureRecognizer(recognizer)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // 入力欄を触ったあとでも、画面をタップすればハードウェアキーボードの入力を Mac に戻す
        if !isFirstResponder {
            becomeFirstResponder()
        }
        click(.left, at: normalized(recognizer.location(in: self)))
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        click(.right, at: normalized(recognizer.location(in: self)))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        click(.right, at: normalized(recognizer.location(in: self)))
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            // 認識されるまでに指は少し動いているので、触れた位置から押し始める
            let translation = recognizer.translation(in: self)
            let start = normalized(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            send?(.mouseMove(start))
            send?(.mouseButton(.left, isDown: true, at: start))
            send?(.mouseMove(normalized(location)))
        case .changed:
            send?(.mouseMove(normalized(location)))
        case .ended, .cancelled, .failed:
            send?(.mouseButton(.left, isDown: false, at: normalized(location)))
        default:
            break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        switch recognizer.state {
        case .began:
            lastScrollTranslation = .zero
            // スクロールはカーソルの下にあるものに効くので、先に指の位置へカーソルを移す
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

    private func click(_ button: MouseButton, at point: NormalizedPoint) {
        send?(.mouseMove(point))
        send?(.mouseButton(button, isDown: true, at: point))
        send?(.mouseButton(button, isDown: false, at: point))
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
