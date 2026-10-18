import SwiftUI

/// 画面の隅に浮かぶ操作パネル。Mac の画面を隠さないよう小さくまとめ、ドラッグで好きな隅へ動かせる。
struct FloatingControls: View {
    private enum Corner: String {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    let model: AppModel
    let session: HostSession
    @Binding var isTyping: Bool
    @AppStorage("floatingControlsCorner") private var cornerName = Corner.bottomTrailing.rawValue
    @State private var dragOffset = CGSize.zero
    @State private var isShowingGuide = false

    var body: some View {
        GeometryReader { proxy in
            panel
                .padding(.horizontal, Self.margin)
                .padding(.vertical, verticalMargin(in: proxy))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                .offset(dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            // 指を離した位置に近い隅へ吸い付かせる
                            let isLeading = value.location.x < proxy.size.width / 2
                            let isTop = value.location.y < proxy.size.height / 2
                            withAnimation(.spring(duration: 0.3)) {
                                cornerName = (isTop ? (isLeading ? Corner.topLeading : .topTrailing) : (isLeading ? .bottomLeading : .bottomTrailing)).rawValue
                                dragOffset = .zero
                            }
                        }
                )
        }
    }

    private var corner: Corner {
        Corner(rawValue: cornerName) ?? .bottomTrailing
    }

    private static let margin: CGFloat = 16
    // ボタン 44pt と上下の余白 4pt ずつ
    private static let panelHeight: CGFloat = 52

    /// Mac の画面が iPad より横長だと、上下に黒い帯ができる (16:9 の外部ディスプレイなら横向きで 78pt)。
    /// パネルが帯に収まるなら、Mac の画面の端に重ならないよう帯の中に置く。
    private func verticalMargin(in proxy: GeometryProxy) -> CGFloat {
        let video = session.videoSize
        let insets = proxy.safeAreaInsets
        let edgeInset = corner.alignment.vertical == .top ? insets.top : insets.bottom
        guard !isTyping, video.width > 0, video.height > 0 else { return Self.margin }
        let screen = CGSize(width: proxy.size.width + insets.leading + insets.trailing, height: proxy.size.height + insets.top + insets.bottom)
        let band = (screen.height - min(screen.height, screen.width * video.height / video.width)) / 2
        guard band >= Self.panelHeight + 8 else { return Self.margin }
        // 画面の端からの距離で決め、Mac の画面を映す範囲と同じく安全領域を無視する
        return min(Self.margin + edgeInset, (band - Self.panelHeight) / 2) - edgeInset
    }

    private var panel: some View {
        HStack(spacing: 4) {
            // Typeless で話したあとにそのまま送れるよう、キーボードを出さなくても押せる場所に置く
            PanelButton(title: "Enter", systemImage: "return", isActive: false) {
                session.tapKey(usage: HIDUsage.returnKey)
            }
            TypelessButton(session: session)
                .frame(width: 44, height: 44)
            PanelButton(title: isTyping ? "キーボードを閉じる" : "キーボード", systemImage: isTyping ? "keyboard.chevron.compact.down" : "keyboard", isActive: isTyping) {
                isTyping.toggle()
            }
            PanelButton(title: "アプリ切替", systemImage: "rectangle.2.swap", isActive: false, action: session.switchApp)
            Menu {
                if session.displays.count > 1 {
                    Section("映す画面") {
                        Picker("映す画面", selection: Binding(get: { session.shownDisplayID ?? 0 }, set: { session.selectDisplay($0) })) {
                            ForEach(session.displays) { display in
                                Text(display.label).tag(display.id)
                            }
                        }
                        .pickerStyle(.inline)
                        // 画面をまたいでドラッグできない代わりに、手前のウィンドウを選んだ画面へ移す
                        Menu("手前のウィンドウを移す", systemImage: "macwindow") {
                            ForEach(session.displays) { display in
                                Button(display.label) { session.moveFrontWindow(to: display.id) }
                            }
                        }
                    }
                }
                Toggle("Mac の音を iPad で鳴らす", systemImage: "speaker.wave.2", isOn: Binding(get: { session.playsMacAudio }, set: { session.setPlaysMacAudio($0) }))
                Button("操作の一覧", systemImage: "hand.tap") { isShowingGuide = true }
                Button("切断", systemImage: "xmark.circle", role: .destructive, action: model.disconnect)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("その他")
            .sheet(isPresented: $isShowingGuide) {
                GestureGuideView()
            }
        }
        .foregroundStyle(.primary)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct PanelButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(isActive ? Color.accentColor.opacity(0.3) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
