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
            // キーボードの領域は避けて縮み、打っている場所が隠れないようにする
            RemoteScreenView(session: session)
                .ignoresSafeArea(.container)
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
            if let notice = permissionNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            Spacer()
        }
        .padding()
        switch session.phase {
        case .connecting:
            ProgressView("\(session.host.name) に接続中…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .reconnecting:
            ProgressView("\(session.host.name) に再接続中…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .connected:
            EmptyView()
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
}
