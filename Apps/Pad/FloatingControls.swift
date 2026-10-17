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

    var body: some View {
        GeometryReader { proxy in
            panel
                .padding(16)
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
                Button("切断", systemImage: "xmark.circle", role: .destructive, action: model.disconnect)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("その他")
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
