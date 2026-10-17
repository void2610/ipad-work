import SwiftUI

@main
struct PadBridgeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = model.session {
                    SessionView(model: model, session: session)
                } else {
                    HostListView(model: model)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.reconnectIfNeeded()
                }
            }
        }
    }
}
