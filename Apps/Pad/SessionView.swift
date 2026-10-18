import PadBridgeKit
import SwiftUI

/// Mac の画面を全面に映し、操作は隅に浮かぶパネルとキーボードの上の列にまとめる。
struct SessionView: View {
    let model: AppModel
    let session: HostSession
    @State private var isTyping = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            // キーボードの分は RemoteScreenView が UIKit のキーボードの位置から自分で縮める
            RemoteScreenView(session: session)
                .ignoresSafeArea()
            statusOverlay
            FloatingControls(model: model, session: session, isTyping: $isTyping)
            DirectTypingField(session: session, isActive: $isTyping)
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .persistentSystemOverlays(.hidden)
        // 画面の端を触ったときに、Mac の操作より先に iPadOS のジェスチャーが反応しないようにする
        .defersSystemGestures(on: .all)
        .statusBarHidden()
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack {
            ForEach([permissionNotice, relayNotice, session.microphoneNotice].compactMap(\.self), id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            ForEach(session.notices) { notice in
                Label(notice.text, systemImage: notice.systemImage)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
            Spacer()
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: session.notices)
        switch session.phase {
        case .connecting:
            connectingView("\(session.host.name) に接続中…")
        case .reconnecting:
            connectingView("\(session.host.name) に再接続中…")
        case .connected:
            EmptyView()
        }
    }

    private func connectingView(_ title: String) -> some View {
        VStack(spacing: 10) {
            ProgressView(title)
            if session.isUnreachable {
                Text("Mac に届きません。Mac が眠っていないか、Mac の PadBridge Host が動いているかを確かめてください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionNotice: String? {
        guard let status = session.hostStatus else { return nil }
        var missing: [String] = []
        if !status.canCaptureScreen { missing.append("画面収録") }
        if !status.canControlInput { missing.append("アクセシビリティ") }
        guard !missing.isEmpty else { return nil }
        return "Mac の PadBridge Host で「\(missing.joined(separator: "」と「"))」を許可してください。"
    }

    private var relayNotice: String? {
        guard let status = session.hostStatus else { return nil }
        if !status.canRelayMicrophone {
            return "iPad のマイクを Mac に渡すには、Mac で「PadBridge Host」に「システムオーディオの録音」を許可してください。"
        }
        if status.typelessUsesOtherMicrophone {
            return "Typeless が iPad ではないマイクで聞き取っていました。Typeless のマイクが「自動検出」なら、この聞き取りのあと Mac が「PadBridge iPad マイク」に切り替えます (Typeless で選んだマイクは変えません)。"
        }
        if status.typelessCannotReadPadMicrophone {
            return "Typeless が iPad のマイクを読めません。Mac で「画面とシステムオーディオの録音」の設定を開いたので、下の「システムオーディオ録音のみ」の「＋」で Typeless を加えてください。"
        }
        return nil
    }
}
