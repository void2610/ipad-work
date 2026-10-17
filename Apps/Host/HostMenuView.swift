import AppKit
import SwiftUI

struct HostMenuView: View {
    let controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PadBridge Host").font(.headline)
                Spacer()
                Text(statusText).foregroundStyle(.secondary)
            }

            GroupBox("ペアリングコード") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.pairingCode.formatted)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text("初回接続時に iPad で入力します。").font(.caption).foregroundStyle(.secondary)
                    Button("コードを再発行") { controller.regeneratePairingCode() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("権限") {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionRow(title: "画面収録", detail: "画面を iPad に映す", granted: controller.canCaptureScreen) {
                        controller.requestScreenCapture()
                    }
                    PermissionRow(title: "アクセシビリティ", detail: "iPad からの操作と文字入力", granted: controller.canControlInput) {
                        controller.requestAccessibility()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("再起動") { controller.relaunch() }
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { controller.refreshPermissions() }
    }

    private var statusText: String {
        if let name = controller.connectedDeviceName {
            return "\(name) と接続中"
        }
        return controller.listenerDescription
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("許可する", action: request)
            }
        }
    }
}
