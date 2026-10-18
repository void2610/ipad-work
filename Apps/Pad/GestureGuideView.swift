import SwiftUI

/// iPad での操作と、Mac での動作の一覧。「…」から開く。
struct GestureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let gesture: String
        let action: String
        var id: String { gesture }
    }

    private static let sections: [(title: String, items: [Item])] = [
        ("指", [
            Item(gesture: "1 本指でタップ", action: "クリック (続けてタップするとダブルクリック)"),
            Item(gesture: "1 本指でスワイプ・2 本指で動かす", action: "スクロール (指を離すと止まる)"),
            Item(gesture: "長押ししてから動かす", action: "ドラッグ"),
            Item(gesture: "長押しして離す・2 本指で短くタップ", action: "右クリック"),
            Item(gesture: "2 本指で広げる・縮める", action: "iPad の上で拡大・縮小 (5 倍まで。縮めきると等倍)"),
            Item(gesture: "3 本指で左右にスワイプ", action: "操作スペースの切り替え (左へスワイプすると右の操作スペースへ)"),
            Item(gesture: "3 本指で上へスワイプ", action: "Mission Control"),
            Item(gesture: "3 本指で下へスワイプ", action: "アプリケーションウインドウ"),
            Item(gesture: "画面の下端から上へスワイプ", action: "Dock を表示 (Dock が別のディスプレイにあれば、そのディスプレイに切り替え)"),
        ]),
        ("トラックパッド・マウス・Apple Pencil", [
            Item(gesture: "クリック", action: "そのままクリック (副ボタンは右クリック)"),
            Item(gesture: "Apple Pencil で触れる・触れたまま動かす", action: "クリック・そのままドラッグ"),
            Item(gesture: "ホバー", action: "カーソル移動"),
        ]),
        ("キーボード", [
            Item(gesture: "ハードウェアキーボード", action: "そのままキー入力 (長押しでキーリピート。⌘ を押しながらタップで ⌘クリック)"),
            Item(gesture: "⌘Space・⌘N・⌘O・⌘R・⌘M・⌘H・⌘Q", action: "iPadOS が受け取ってしまうので、「…」の「Mac のショートカット」から送る"),
            Item(gesture: "キーボード上部のバーの ⌃ ⌥ ⌘ ⇧", action: "次の 1 回だけ有効。2 回続けて押すとロック"),
            Item(gesture: "キーボード上部のバーの英数・かな", action: "Mac の入力モードを切り替える。現在の入力モードが青く表示される"),
            Item(gesture: "キーボード上部のバーのペースト", action: "iPad でコピーしたテキストを Mac の入力欄に貼り付ける"),
        ]),
        ("操作パネル", [
            Item(gesture: "Enter", action: "Mac の Return キー"),
            Item(gesture: "マイク", action: "Mac の Typeless で音声入力を開始・終了"),
            Item(gesture: "アプリ切替", action: "⌘Tab。タップごとに次のアプリへ進み、1 秒で確定"),
            Item(gesture: "パネルをドラッグ", action: "好きな隅へ移動"),
        ]),
        ("「…」メニュー", [
            Item(gesture: "表示するディスプレイ", action: "Mac にディスプレイが 2 台以上あるとき、iPad に表示するディスプレイを選ぶ"),
            Item(gesture: "最前面のウィンドウを移動", action: "最前面のウィンドウを選んだディスプレイへ移動し、そのディスプレイを表示"),
            Item(gesture: "Mac のサウンドを iPad で再生", action: "Mac のサウンドを iPad で再生 (その間 Mac のスピーカーからは再生されない)"),
            Item(gesture: "Mac のショートカット", action: "iPadOS が受け取ってしまうショートカットを Mac へ送る"),
            Item(gesture: "接続状況", action: "映像の画質・フレームレート・遅延を確認 (動作が重いときに)"),
            Item(gesture: "切断", action: "Mac との接続を切断して、Mac の一覧に戻る"),
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.gesture).font(.headline)
                                Text(item.action).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("操作一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
