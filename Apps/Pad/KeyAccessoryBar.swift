import Observation
import PadBridgeKit
import UIKit

/// キーボードを出している間だけ、そのすぐ上に出る特殊キーの列。ソフトウェアキーボードにない esc・修飾キー・矢印・英数/かなを置く。
final class KeyAccessoryBar: UIInputView {
    private enum Key {
        case tap(String, usage: Int, repeats: Bool)
        case modifier(String, KeyModifiers)
        case gap
    }

    private static let keys: [Key] = [
        .tap("esc", usage: 0x29, repeats: false),
        .tap("⇥", usage: 0x2B, repeats: false),
        .gap,
        .modifier("⌃", .control),
        .modifier("⌥", .option),
        .modifier("⌘", .command),
        .modifier("⇧", .shift),
        .gap,
        .tap("←", usage: KeyboardMapping.ArrowUsage.left, repeats: true),
        .tap("↓", usage: KeyboardMapping.ArrowUsage.down, repeats: true),
        .tap("↑", usage: KeyboardMapping.ArrowUsage.up, repeats: true),
        .tap("→", usage: KeyboardMapping.ArrowUsage.right, repeats: true),
        .gap,
        // iPad のソフトウェアキーボードには Mac の日本語入力を切り替えるキーがないので、JIS キーボードの英数・かなを置く
        .tap("英数", usage: 0x91, repeats: false),
        .tap("かな", usage: 0x90, repeats: false),
    ]

    private weak var session: HostSession?
    private var modifierButtons: [(KeyModifiers, KeyCapButton)] = []

    init(session: HostSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        buildKeys()
        observeModifiers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 52)
    }

    private func buildKeys() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        for key in Self.keys {
            switch key {
            case let .tap(title, usage, repeats):
                let button = RepeatingButton(title: title, repeats: repeats) { [weak self] in
                    self?.session?.tapKey(usage: usage)
                }
                stack.addArrangedSubview(button)
            case let .modifier(title, modifier):
                let button = KeyCapButton(title: title)
                button.addAction(UIAction { [weak self] _ in self?.session?.toggleModifier(modifier) }, for: .primaryActionTriggered)
                modifierButtons.append((modifier, button))
                stack.addArrangedSubview(button)
            case .gap:
                let spacer = UIView()
                spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
                stack.addArrangedSubview(spacer)
            }
        }

        // 縦向きなどで幅が足りなくても、全部のキーに横へずらして届くようにする
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 40),
            // キーが少なく幅に余るときは中央に寄せる
            stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor).withPriority(.defaultLow),
            scroll.contentLayoutGuide.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    /// 修飾キーは、次の 1 回だけ効く状態と固定した状態を色の濃さで見せる。クリックで外れたときも追従させる。
    private func observeModifiers() {
        withObservationTracking {
            refreshModifiers()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeModifiers() }
        }
    }

    private func refreshModifiers() {
        guard let session else { return }
        for (modifier, button) in modifierButtons {
            button.showLatchState(session.modifierLatch.state(of: modifier))
        }
    }
}

/// キーボードのキーに似せたボタン。
fileprivate class KeyCapButton: UIButton {
    init(title: String) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 17, weight: .medium)
            return attributes
        }
        self.configuration = configuration
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showLatchState(_ state: ModifierLatch.State) {
        var configuration = self.configuration
        switch state {
        case .off:
            configuration?.baseBackgroundColor = nil
            configuration?.baseForegroundColor = nil
        case .once:
            configuration?.baseBackgroundColor = .tintColor.withAlphaComponent(0.35)
            configuration?.baseForegroundColor = .label
        case .locked:
            configuration?.baseBackgroundColor = .tintColor
            configuration?.baseForegroundColor = .white
        }
        self.configuration = configuration
        accessibilityValue = state == .off ? "オフ" : state == .once ? "次の 1 回" : "固定"
    }
}

/// 押した瞬間に 1 回送り、押し続けると実際のキーボードと同じく繰り返す。
private final class RepeatingButton: KeyCapButton {
    private let fire: () -> Void
    private let repeats: Bool
    private var timer: Timer?

    init(title: String, repeats: Bool, fire: @escaping () -> Void) {
        self.fire = fire
        self.repeats = repeats
        super.init(title: title)
        addAction(UIAction { [weak self] _ in self?.press() }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
        }
    }

    private func press() {
        fire()
        guard repeats else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
            }
        }
    }

    private func stopRepeating() {
        timer?.invalidate()
        timer = nil
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
