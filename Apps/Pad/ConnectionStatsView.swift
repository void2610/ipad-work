import PadBridgeKit
import SwiftUI

/// Mac から受信している映像とオーディオの状態。遅い・カクつくと感じたときに、回線が原因かを確認できるようにする。「…」から開く。
struct ConnectionStatsView: View {
    @Environment(\.dismiss) private var dismiss
    let session: HostSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let stats = session.videoStats {
                        row("形式", "\(stats.codec == .hevc ? "HEVC" : "H.264")・\(stats.width)×\(stats.height)")
                        row("画質", Self.quality(stats))
                        if let rate = session.receivedRate {
                            row("受信している映像", String(format: "%.0f fps・%.1f Mbps", rate.framesPerSecond, rate.megabitsPerSecond))
                        }
                        row("往復遅延 (RTT)", stats.roundTripMillis.map { "\($0) ms" } ?? "計測中")
                        if let frameRate = stats.frameRate {
                            row("最大フレームレート", frameRate < PreferredFrameRate.normal ? "\(frameRate) fps (低電力モードまたは本体の温度上昇のため下げています)" : "\(frameRate) fps")
                        }
                    } else {
                        Text("Mac から映像の情報を待っています")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("映像")
                } footer: {
                    Text("2 秒ごとに更新します。画面に変化がない間は Mac が映像を送らないため、フレームレートは 0 になります。往復遅延は、Mac がフレームを送信してから iPad の受信確認が届くまでの時間です。")
                }
                Section("接続") {
                    if let route = session.route {
                        row("経路", route)
                    }
                    // 片方だけ古いビルドのまま動いていないかを確認できるように
                    row("ビルド (iPad)", BuildCommit.current() ?? "不明")
                    row("ビルド (Mac)", session.hostCommit ?? "不明")
                }
                Section("サウンド") {
                    row("Mac のサウンド", session.playsMacAudio ? (BackgroundAudio.shared.macAudio.canDecodeOpus ? "Opus で再生中" : "非圧縮で再生中") : "再生していません")
                }
            }
            .navigationTitle("接続状況")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private static func quality(_ stats: VideoStats) -> String {
        let current = String(format: "%.1f Mbps", Double(stats.bitRate) / 1_000_000)
        guard stats.bitRate < stats.maximumBitRate else { return current }
        return current + String(format: " (回線状況に合わせて低下中。最大 %.1f Mbps)", Double(stats.maximumBitRate) / 1_000_000)
    }
}
