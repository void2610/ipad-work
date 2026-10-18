import AppKit
import PadBridgeKit
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
                Label("iPad に表示中のディスプレイ: \(display)", systemImage: "display")
                    .font(.caption)
            }

            if let padCommit = controller.mismatchedPadCommit {
                Label("iPad アプリとビルドが一致しません (iPad: \(padCommit)、Mac: \(BuildCommit.current() ?? "?"))", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }

            // iPad で映像が遅い・粗いと言われたときに、Mac の前でも回線のせいかを見られるように
            if let stats = controller.videoStatsOnPad {
                Label("iPad への配信: \(stats.summary)", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
            }

            // Mac の前にいる人が、Mac から音が出ない理由を分かるようにする
            if controller.isPlayingMacAudioOnPad {
                Label("Mac のサウンドを iPad で再生中です。Mac のスピーカーからは再生されません。", systemImage: "speaker.wave.2")
                    .font(.caption)
            }

            GroupBox("権限") {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionRow(title: "画面収録", detail: "画面を iPad に表示する", granted: controller.canCaptureScreen) {
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
                    PermissionRow(title: "PadBridge Host", detail: "システムオーディオの録音 (iPad のマイクを Mac で使う)", granted: controller.canRelayMicrophone) {
                        controller.openAudioCaptureSettings()
                    }
                    PermissionRow(title: "Typeless", detail: "「システムオーディオ録音のみ」に追加する", granted: !controller.typelessCannotReadPadMicrophone) {
                        controller.openAudioCaptureSettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchesAtLogin($0) })) {
                VStack(alignment: .leading) {
                    Text("ログイン時に起動")
                    Text("Mac を再起動しても、蓋を閉じたまま iPad から接続できます").font(.caption).foregroundStyle(.secondary)
                }
            }

            // どの組み立てが動いているかを、iPad の「接続の状態」と見比べられるように
            Text("ビルド: \(BuildCommit.current() ?? "不明")")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
