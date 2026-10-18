import SwiftUI
import UIKit

/// Mac の Typeless の push-to-talk を iPad から押すボタン。押している間だけ聞き取らせ、短く押した場合はもう一度押すまで押しっぱなしにする。
struct TypelessButton: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context _: Context) -> PushToTalkButton {
        let button = PushToTalkButton()
        button.onActiveChange = { [weak session] isActive in session?.setVoiceInput(isActive) }
        button.levelProvider = { [weak session] in session?.microphoneLevel ?? 0 }
        return button
    }

    func updateUIView(_ button: PushToTalkButton, context _: Context) {
        button.isVoiceInputActive = session.isVoiceInputActive
    }

    func sizeThatFits(_: ProposedViewSize, uiView _: PushToTalkButton, context _: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }
}

/// SwiftUI のジェスチャーは、システムに押下を奪われたキャンセルと指を離したことを区別できず、聞き取りが一瞬で切れる。
/// UIControl の追跡なら区別できるので、キャンセルされたときは押しっぱなしに切り替えて聞き取りを続ける。
final class PushToTalkButton: UIButton {
    var onActiveChange: ((Bool) -> Void)?
    /// iPad のマイクで拾っている声の大きさ (0...1)。聞き取りの間、ボタンの周りの輪で見せる。
    var levelProvider: (() -> Float)?

    /// Mac 側の実際の状態。裏に回ったときなど、ボタン以外の理由で離されたらここで知らされる。
    var isVoiceInputActive = false {
        didSet {
            if !isVoiceInputActive {
                isLatched = false
            }
            updateAppearance()
            updateLevelDisplay()
        }
    }

    // 声の大きさの輪。iPad のマイクが声を拾っているかを、話しながら確かめられるようにする
    private let levelRing = CAShapeLayer()
    private var levelLink: CADisplayLink?
    private var shownLevel: CGFloat = 0

    private static let latchThreshold: TimeInterval = 0.35
    private var isLatched = false
    private var pressStartedAt: TimeInterval?
    // 押しっぱなしを解除したタッチは、指を離したときに何もしない
    private var isReleasingLatch = false

    init() {
        super.init(frame: .zero)
        accessibilityLabel = "Typeless"
        levelRing.fillColor = nil
        levelRing.strokeColor = UIColor.systemRed.withAlphaComponent(0.45).cgColor
        levelRing.opacity = 0
        layer.insertSublayer(levelRing, at: 0)
        updateAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        levelRing.frame = bounds
        levelRing.path = UIBezierPath(ovalIn: bounds.insetBy(dx: -3, dy: -3)).cgPath
    }

    override func removeFromSuperview() {
        levelLink?.invalidate()
        levelLink = nil
        super.removeFromSuperview()
    }

    private func updateLevelDisplay() {
        if isVoiceInputActive, levelLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepLevel))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
            link.add(to: .main, forMode: .common)
            levelLink = link
        } else if !isVoiceInputActive {
            levelLink?.invalidate()
            levelLink = nil
            shownLevel = 0
            levelRing.opacity = 0
        }
    }

    @objc private func stepLevel() {
        // 上がるときはすぐ、下がるときはゆっくり動かして、ちらつかないようにする
        let level = CGFloat(levelProvider?() ?? 0)
        shownLevel = max(level, shownLevel * 0.85)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelRing.lineWidth = 2 + shownLevel * 8
        levelRing.opacity = shownLevel > 0.02 ? 1 : 0
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if isVoiceInputActive {
            isReleasingLatch = true
            isLatched = false
            onActiveChange?(false)
        } else {
            isReleasingLatch = false
            pressStartedAt = touch.timestamp
            onActiveChange?(true)
        }
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        defer { pressStartedAt = nil }
        guard !isReleasingLatch, let pressStartedAt, let touch else { return }
        if touch.timestamp - pressStartedAt < Self.latchThreshold {
            isLatched = true
        } else {
            onActiveChange?(false)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        // 指はまだ画面にあるかもしれないので、聞き取りは止めずに押しっぱなしへ切り替える
        if !isReleasingLatch, pressStartedAt != nil {
            isLatched = true
        }
        pressStartedAt = nil
    }

    private func updateAppearance() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: isVoiceInputActive ? "waveform" : "mic.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(weight: .semibold)
        configuration.baseBackgroundColor = isVoiceInputActive ? .systemRed : .tintColor
        configuration.contentInsets = .zero
        self.configuration = configuration
        accessibilityValue = isVoiceInputActive ? "音声入力中" : nil
    }
}
