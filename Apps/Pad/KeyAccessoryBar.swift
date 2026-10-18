import Observation
import PadBridgeKit
import UIKit

/// キーボードを出している間だけ、そのすぐ上に出る特殊キーの列。ソフトウェアキーボードにない esc・修飾キー・矢印・英数/かな・長音を置く。
final class KeyAccessoryBar: UIInputView, UIInputViewAudioFeedback {
    private enum Key {
        case tap(String, usage: Int, repeats: Bool)
        case modifier(String, KeyModifiers)
        case gap
        case paste
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
        // 英字配列のキーボードでは - が記号の面にしかないので、かなモードで「ー」になる - のキーを置く
        .tap("ー", usage: 0x2D, repeats: true),
        .gap,
        .paste,
    ]

    private weak var session: HostSession?
    private var modifierButtons: [(KeyModifiers, KeyCapButton)] = []
    // 英数・かなのキー。Mac の文字入力で効いている方を示す
    private var inputModeButtons: [(MacInputMode, KeyCapButton)] = []
    // iPad でコピーした文字を Mac に入れる。システムのペーストボタンなら、iOS がペーストの許可を尋ねない
    private let pasteControl: UIPasteControl = {
        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        // iOS が別に描くので列のダークの見た目に従わない。ほかのキー (ダークの灰色のボタン、実測 #262629) と同じ色を直接渡す
        configuration.baseBackgroundColor = UIColor(red: 0x26 / 255, green: 0x26 / 255, blue: 0x29 / 255, alpha: 1)
        configuration.baseForegroundColor = .white
        return UIPasteControl(configuration: configuration)
    }()

    /// ペーストボタンが押されたときに、コピーした文字を受け取る入力先。
    weak var pasteTarget: UIPasteConfigurationSupporting? {
        get { pasteControl.target }
        set { pasteControl.target = newValue }
    }

    init(session: HostSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
        // 列の後ろは Mac の画面の外の黒い背景なので、ライトモードの黒い文字だとキーの上でほとんど読めない。いつもダークの見た目にする
        overrideUserInterfaceStyle = .dark
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

    // キーを押したときに、iPad のキーボードと同じクリック音を鳴らせるようにする (設定の「キーボードのクリック」に従う)
    var enableInputClicksWhenVisible: Bool {
        true
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
                if let mode = Self.inputMode(ofUsage: usage) {
                    inputModeButtons.append((mode, button))
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
            case .paste:
                pasteControl.widthAnchor.constraint(equalToConstant: 52).isActive = true
                pasteControl.heightAnchor.constraint(equalToConstant: 40).isActive = true
                stack.addArrangedSubview(pasteControl)
            }
        }

        // 縦向きなどで幅が足りなくても、全部のキーに横へずらして届くようにする
        let scroll = KeyScrollView()
        scroll.showsHorizontalScrollIndicator = false
        // 既定ではスクロールかどうかを見極める間キーの押下が遅れ、短く押すと押した表示がほとんど出ない
        scroll.delaysContentTouches = false
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
    /// 英数・かなは、Mac で効いている方を薄い色で見せる。Mac で直接切り替えたときも追従させる。
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
        let inputMode = session.macInputMode
        for (mode, button) in inputModeButtons {
            button.showCurrent(mode == inputMode)
        }
    }

    private static func inputMode(ofUsage usage: Int) -> MacInputMode? {
        switch usage {
        case 0x91: .alphanumeric
        case 0x90: .kana
        default: nil
        }
    }
}

/// キーの上から触れ始めても横へずらせるようにする。
private final class KeyScrollView: UIScrollView {
    override func touchesShouldCancel(in _: UIView) -> Bool {
        true
    }
}

/// キーボードのキーに似せたボタン。
fileprivate class KeyCapButton: UIButton {
    private var latchState = ModifierLatch.State.off
    private var isCurrent = false

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
        addAction(UIAction { _ in UIDevice.current.playInputClick() }, for: .touchDown)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 英数・かなのキーで、Mac の文字入力がこのキーの側になっているか。
    func showCurrent(_ isCurrent: Bool) {
        guard self.isCurrent != isCurrent else { return }
        self.isCurrent = isCurrent
        setNeedsUpdateConfiguration()
        accessibilityValue = isCurrent ? "入力中" : nil
    }

    func showLatchState(_ state: ModifierLatch.State) {
        latchState = state
        setNeedsUpdateConfiguration()
        accessibilityValue = state == .off ? "オフ" : state == .once ? "次の 1 回" : "固定"
    }

    override func updateConfiguration() {
        guard var configuration else { return }
        // 押している間は色と大きさをはっきり変え、指で隠れていても押したことが分かるようにする
        switch (isHighlighted, latchState) {
        case (true, _):
            configuration.baseBackgroundColor = .tintColor
            configuration.baseForegroundColor = .white
        case (false, .off) where isCurrent:
            configuration.baseBackgroundColor = .tintColor.withAlphaComponent(0.35)
            configuration.baseForegroundColor = .label
        case (false, .off):
            configuration.baseBackgroundColor = nil
            configuration.baseForegroundColor = nil
        case (false, .once):
            configuration.baseBackgroundColor = .tintColor.withAlphaComponent(0.35)
            configuration.baseForegroundColor = .label
        case (false, .locked):
            configuration.baseBackgroundColor = .tintColor
            configuration.baseForegroundColor = .white
        }
        self.configuration = configuration
        let transform = isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = transform
        }
    }
}

/// 指を離したときに 1 回送り、押し続けると実際のキーボードと同じく繰り返す。
/// 押した瞬間に送ると、キーの列を横へずらそうとキーの上から触れただけでもキーが送られてしまう。押したことは表示と音ですぐに伝える。
private final class RepeatingButton: KeyCapButton {
    private let fire: () -> Void
    private let repeats: Bool
    private var timer: Timer?
    private var didRepeat = false

    init(title: String, repeats: Bool, fire: @escaping () -> Void) {
        self.fire = fire
        self.repeats = repeats
        super.init(title: title)
        addAction(UIAction { [weak self] _ in self?.press() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.release() }, for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel] {
            addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
        }
    }

    private func press() {
        didRepeat = false
        guard repeats else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.didRepeat = true
                self.fire()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
            }
        }
    }

    private func release() {
        stopRepeating()
        if !didRepeat {
            fire()
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
