import PadBridgeKit
import SwiftUI

struct SessionView: View {
    let model: AppModel
    let session: HostSession
    @State private var draft = ""
    @State private var isDirectTyping = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RemoteScreenView(session: session)
                switch session.phase {
                case .connecting:
                    ProgressView("\(session.host.name) に接続中…")
                        .tint(.white)
                        .foregroundStyle(.white)
                case .reconnecting:
                    ProgressView("\(session.host.name) に再接続中…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                case .connected:
                    EmptyView()
                }
                VStack {
                    if let notice = permissionNotice {
                        Banner(text: notice, systemImage: "exclamationmark.triangle.fill")
                    }
                    Spacer()
                }
                .padding()
            }
            controlBar
        }
        .background(.black)
        .persistentSystemOverlays(.hidden)
        // 画面の端を触ったときに、Mac の操作より先に iPadOS のジェスチャーが反応しないようにする
        .defersSystemGestures(on: .all)
        .statusBarHidden()
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button("切断", systemImage: "xmark", action: model.disconnect)
                .labelStyle(.iconOnly)
            // 縦向きなどで幅が足りなくても、キーのボタンは横にずらして全部使えるようにする
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KeyButton(label: "esc", usage: HIDUsage.escape, session: session)
                    KeyButton(label: "⇥", usage: HIDUsage.tab, session: session)
                    KeyButton(label: "⌫", usage: HIDUsage.backspace, session: session, repeats: true)
                    KeyButton(label: "⏎", usage: HIDUsage.returnKey, session: session)
                    KeyButton(label: "←", usage: KeyboardMapping.ArrowUsage.left, session: session, repeats: true)
                    KeyButton(label: "↑", usage: KeyboardMapping.ArrowUsage.up, session: session, repeats: true)
                    KeyButton(label: "↓", usage: KeyboardMapping.ArrowUsage.down, session: session, repeats: true)
                    KeyButton(label: "→", usage: KeyboardMapping.ArrowUsage.right, session: session, repeats: true)
                    ModifierButton(label: "⌘", modifier: .command, session: session)
                    ModifierButton(label: "⌥", modifier: .option, session: session)
                    ModifierButton(label: "⌃", modifier: .control, session: session)
                    ModifierButton(label: "⇧", modifier: .shift, session: session)
                    Button("アプリ切替", systemImage: "square.stack.3d.up", action: session.switchApp)
                        .labelStyle(.iconOnly)
                    Button(isDirectTyping ? "キーボードを閉じる" : "キーボード", systemImage: isDirectTyping ? "keyboard.chevron.compact.down" : "keyboard") {
                        isDirectTyping.toggle()
                    }
                    .labelStyle(.iconOnly)
                }
            }
            TextField("日本語はここで変換して送る", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .frame(minWidth: 160, maxWidth: 280)
            Button("送信", action: sendDraft)
                .disabled(draft.isEmpty)
            TypelessButton(session: session)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .background {
            DirectTypingField(session: session, isActive: $isDirectTyping)
                .frame(width: 1, height: 1)
                .opacity(0)
        }
    }

    private var permissionNotice: String? {
        guard let status = session.hostStatus else { return nil }
        var missing: [String] = []
        if !status.canCaptureScreen { missing.append("画面収録") }
        if !status.canControlInput { missing.append("アクセシビリティ") }
        guard !missing.isEmpty else { return nil }
        return "Mac の PadBridge Host で「\(missing.joined(separator: "」と「"))」を許可してください。"
    }

    private func sendDraft() {
        guard !draft.isEmpty else { return }
        session.send(.insertText(draft))
        draft = ""
    }
}

/// 押すと次の 1 回にだけ効き (薄く色付き)、続けて 2 回押すと固定される (濃く色付き)。
private struct ModifierButton: View {
    let label: String
    let modifier: KeyModifiers
    let session: HostSession

    var body: some View {
        let state = session.modifierLatch.state(of: modifier)
        Button(label) {
            session.toggleModifier(modifier)
        }
        .font(.body.weight(state == .off ? .regular : .bold))
        .background(highlight(for: state), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityValue(state == .off ? "オフ" : state == .once ? "次の 1 回" : "固定")
    }

    private func highlight(for state: ModifierLatch.State) -> Color {
        switch state {
        case .off: .clear
        case .once: .accentColor.opacity(0.3)
        case .locked: .accentColor.opacity(0.7)
        }
    }
}

private struct KeyButton: View {
    let label: String
    let usage: Int
    let session: HostSession
    var repeats = false

    var body: some View {
        Button(label) {
            session.tapKey(usage: usage)
        }
        .font(.body.monospaced())
        // 矢印や削除は、実際のキーボードと同じく押し続けると繰り返す
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
    }
}
