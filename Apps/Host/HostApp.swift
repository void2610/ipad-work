import SwiftUI

@main
struct PadBridgeHostApp: App {
    @State private var controller = HostController()

    var body: some Scene {
        MenuBarExtra("PadBridge", systemImage: controller.connectedDeviceName == nil ? "ipad.landscape" : "ipad.landscape.badge.play") {
            HostMenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
