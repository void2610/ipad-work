import PadBridgeKit
import SwiftUI

struct SessionView: View {
    let model: AppModel
    let session: HostSession
    @State private var draft = ""

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
        HStack(spacing: 10) {
            Button("切断", systemImage: "xmark", action: model.disconnect)
                .labelStyle(.iconOnly)
            KeyButton(label: "esc", usage: 0x29, session: session)
            KeyButton(label: "⇥", usage: 0x2B, session: session)
            KeyButton(label: "⌫", usage: 0x2A, session: session)
            KeyButton(label: "⏎", usage: 0x28, session: session)
            TextField("ここに入力して Mac へ送る", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button("送信", action: sendDraft)
                .disabled(draft.isEmpty)
            TypelessButton(session: session)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

private struct KeyButton: View {
    let label: String
    let usage: Int
    let session: HostSession

    var body: some View {
        Button(label) {
            session.send(.key(usage: usage, isDown: true, modifiers: []))
            session.send(.key(usage: usage, isDown: false, modifiers: []))
        }
        .font(.body.monospaced())
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
