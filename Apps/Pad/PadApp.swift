import SwiftUI

@main
struct PadBridgeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = model.session {
                    // 名前の変わった Mac を追うと、セッションが nil を挟まずに替わる。作り直さないと、映像のレイヤーと入力が前のセッションに結びついたまま残る
                    SessionView(model: model, session: session)
                        .id(ObjectIdentifier(session))
                } else {
                    HostListView(model: model)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.setForeground(true)
                case .background: model.setForeground(false)
                // コントロールセンターや Spotlight を出すと、押していたキーを離した知らせがこのアプリに届かない
                case .inactive: model.releaseHeldInput()
                @unknown default: break
                }
            }
        }
    }
}
