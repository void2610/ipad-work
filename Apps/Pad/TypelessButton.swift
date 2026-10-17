import SwiftUI
import UIKit

/// Mac の Typeless の push-to-talk を iPad から押すボタン。押している間だけ聞き取らせ、短く押した場合はもう一度押すまで押しっぱなしにする。
struct TypelessButton: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context _: Context) -> PushToTalkButton {
        let button = PushToTalkButton()
        button.onActiveChange = { [weak session] isActive in session?.setVoiceInput(isActive) }
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

    /// Mac 側の実際の状態。裏に回ったときなど、ボタン以外の理由で離されたらここで知らされる。
    var isVoiceInputActive = false {
        didSet {
            if !isVoiceInputActive {
                isLatched = false
            }
            updateAppearance()
        }
    }

    private static let latchThreshold: TimeInterval = 0.35
    private var isLatched = false
    private var pressStartedAt: TimeInterval?
    // 押しっぱなしを解除したタッチは、指を離したときに何もしない
    private var isReleasingLatch = false

    init() {
        super.init(frame: .zero)
        accessibilityLabel = "Typeless"
        updateAppearance()
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
        accessibilityValue = isVoiceInputActive ? "聞き取り中" : nil
    }
}
