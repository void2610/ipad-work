import PadBridgeKit
import SwiftUI

/// Mac から届いている映像と音の状態。遅い・カクつくと感じたときに、回線のせいかを見られるようにする。「…」から開く。
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
                            row("届いている映像", String(format: "毎秒 %.0f 枚・%.1f Mbps", rate.framesPerSecond, rate.megabitsPerSecond))
                        }
                        row("往復の遅れ", stats.roundTripMillis.map { "\($0) ms" } ?? "この Mac は測らない")
                        if let frameRate = stats.frameRate {
                            row("毎秒の上限", frameRate < PreferredFrameRate.normal ? "\(frameRate) 枚 (低電力モードか本体が熱いので減らしています)" : "\(frameRate) 枚")
                        }
                    } else {
                        Text("映像の状態が Mac から届くのを待っています")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("映像")
                } footer: {
                    Text("2 秒ごとに更新します。画面が止まっている間は、Mac は映像を送らないので枚数は 0 になります。往復の遅れは、Mac がフレームを送ってから iPad の受け取りの返事が届くまでの時間です。")
                }
                Section("音") {
                    row("Mac の音", session.playsMacAudio ? (BackgroundAudio.shared.macAudio.canDecodeOpus ? "Opus で鳴らしています" : "無圧縮で鳴らしています") : "鳴らしていません")
                }
            }
            .navigationTitle("接続の状態")
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
        return current + String(format: " (回線に合わせて下げています。上限 %.1f Mbps)", Double(stats.maximumBitRate) / 1_000_000)
    }
}
