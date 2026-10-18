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

            Text("同じネットワークの iPad で PadBridge を開くと接続できます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let display = controller.shownDisplayOnPad {
                Label("iPad に映している画面: \(display)", systemImage: "display")
                    .font(.caption)
            }

            // Mac の前にいる人が、Mac から音が出ない理由を分かるようにする
            if controller.isPlayingMacAudioOnPad {
                Label("Mac の音は iPad で鳴らしています。Mac のスピーカーからは鳴りません。", systemImage: "speaker.wave.2")
                    .font(.caption)
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

            // 蓋を閉じた Mac で iPad のマイクを使うときに要る許可。iPad をつなぐまでは分からないので、分かったものだけ出す
            GroupBox("iPad のマイク") {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionRow(title: "PadBridge Host", detail: "システムオーディオの録音 (iPad の声を渡す)", granted: controller.canRelayMicrophone) {
                        controller.openAudioCaptureSettings()
                    }
                    PermissionRow(title: "Typeless", detail: "「システムオーディオ録音のみ」に加える", granted: !controller.typelessCannotReadPadMicrophone) {
                        controller.openAudioCaptureSettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchesAtLogin($0) })) {
                VStack(alignment: .leading) {
                    Text("ログイン時に起動")
                    Text("蓋を閉じた Mac を再起動しても、iPad からつなげる").font(.caption).foregroundStyle(.secondary)
                }
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
