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
                if session.phase == .connecting {
                    ProgressView("\(session.host.name) に接続中…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                VStack {
                    if let notice = permissionNotice {
                        Banner(text: notice, systemImage: "exclamationmark.triangle.fill")
                    }
                    if let error = model.dictation.errorMessage {
                        Banner(text: error, systemImage: "mic.slash.fill")
                    }
                    Spacer()
                    if model.dictation.state != .idle {
                        DictationPreview(dictation: model.dictation)
                    }
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
            DictationButton(dictation: model.dictation) { text in
                session.send(.insertText(text))
            }
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

private struct DictationPreview: View {
    let dictation: DictationController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: dictation.state == .listening)
            Text(previewText)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var previewText: String {
        if let status = dictation.statusMessage { return status }
        if dictation.transcript.isEmpty { return dictation.state == .listening ? "話してください…" : "準備中…" }
        return dictation.transcript
    }
}
