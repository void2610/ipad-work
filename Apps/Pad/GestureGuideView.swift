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
            Item(gesture: "1 本指で払う・2 本指で動かす", action: "スクロール (離したあとは慣性で流れる)"),
            Item(gesture: "長押ししてから動かす", action: "ドラッグ"),
            Item(gesture: "長押しして離す・2 本指で短くタップ", action: "右クリック"),
            Item(gesture: "2 本指で広げる・縮める", action: "iPad の上で拡大・縮小 (5 倍まで。縮めきると等倍)"),
            Item(gesture: "3 本指で左右に払う", action: "操作スペースの切り替え (左へ払うと右隣へ)"),
            Item(gesture: "3 本指で上へ払う", action: "Mission Control"),
            Item(gesture: "3 本指で下へ払う", action: "アプリケーションウインドウ"),
            Item(gesture: "画面の下端から上へ払う", action: "Dock を出す (Dock が別の画面にあれば、その画面を映す)"),
        ]),
        ("トラックパッド・マウス・Apple Pencil", [
            Item(gesture: "クリック", action: "そのままクリック (副ボタンは右クリック)"),
            Item(gesture: "Apple Pencil で触れる・触れたまま動かす", action: "クリック・そのままドラッグ"),
            Item(gesture: "ホバー", action: "カーソル移動"),
        ]),
        ("キーボード", [
            Item(gesture: "ハードウェアキーボード", action: "そのままキー入力 (押し続けると繰り返す。⌘ を押しながらタップで ⌘クリック)"),
            Item(gesture: "⌘Space・⌘N・⌘O・⌘R・⌘M・⌘H・⌘Q", action: "iPadOS が受け取ってしまうので、「…」の「Mac のショートカット」から送る"),
            Item(gesture: "特殊キーの列の ⌃ ⌥ ⌘ ⇧", action: "次の 1 回だけ効く。続けて 2 回押すと固定"),
            Item(gesture: "特殊キーの列の英数・かな", action: "Mac の日本語入力を切り替える。効いている方が青くなる"),
            Item(gesture: "特殊キーの列のペースト", action: "iPad でコピーした文字を Mac の入力欄に入れる"),
        ]),
        ("操作パネル", [
            Item(gesture: "Enter", action: "Mac の Return キー"),
            Item(gesture: "マイク", action: "Mac の Typeless で音声入力を始める・終える"),
            Item(gesture: "アプリ切替", action: "⌘Tab。タップごとに次のアプリへ進み、1 秒で確定"),
            Item(gesture: "パネルをドラッグ", action: "好きな隅へ動かす"),
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
            .navigationTitle("操作の一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
