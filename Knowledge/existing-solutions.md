# iPad から Mac を操作する／iPad のマイクで Mac の Typeless に入力する: 既存ソフトの調査

調査日: 2026-10-17 / Mac: MacBook Pro (M5), macOS 26.2 / Typeless 2.8.2

## 目的

1. 同じ LAN・同じ Apple アカウントの iPad から Mac を手軽に操作したい
2. iPad のマイクで Mac 上の音声入力ソフト (Typeless) に入力したい

## 要件の補足 (2026-10-17)

- 画面操作は **ミラーリング** で行いたい。Mac の画面をそのまま iPad に映して操作する形で、iPad をサブディスプレイ (拡張デスクトップ) にする形ではない。

## 結論

- ミラーリングで操作するなら、本命は **リモートデスクトップ系のアプリ** (Jump Desktop、Screens 5)。どれも Mac の実際の画面をそのまま映す方式で、今の macOS 26.2 のままで使える。
  - Jump Desktop の Direct Touch モードは、タップした位置をそのままクリックする。ただし、このモードではピンチでの拡大縮小が使えない。Mac のトラックパッドジェスチャーはほとんど再現されない。
  - Screens 5 は VNC 系のアプリ。音声は送れない。Apple Pencil で入力できる。料金はサブスクリプション (年 $24.99) か買い切り。
- Sidecar も、既定は拡張ディスプレイだが、公式にミラーモード (Mirror Built-in Retina Display) がある。macOS 27 + iPadOS 27 で指によるタッチ操作に対応したが、**ミラーモードでもタッチが効くかを確かめた情報は見つからなかった**。試すには Mac と iPad の両方を 27 に上げる必要がある。
  - iPadOS 27 の iPad は、macOS 26 以前の Mac とは Sidecar を使えない。macOS 27 の Mac と iPadOS 26 の iPad の組み合わせでは Sidecar は使えるが、タッチ操作はできない。
- 自作だけで操作もマイクもまかなう案と、リモートデスクトップ＋マイクアプリを組み合わせる案がある。後者の場合、ミラーリングのアプリを前面に出したまま、マイクのアプリが iPad の背面で録音を続けられることが条件になる。
- **iPad マイク → Mac の Typeless に入れるところは、純正機能では実現できない。** Continuity Camera のマイク機能は iPhone 専用で、iPad は対象外。
- 市販アプリでは「Microphone Link (App Store 上の名前は PC Microphone: Mic for PC)」が iPad に対応しており、Mac 側にシステムのマイクとして現れる。購入前の検証候補の第 1 位。
- Jump Desktop のマイク転送は Mac→Mac 限定で、iPad からは使えない。Passmic は iPhone のみ。AudioRelay は Android のみ。

## 候補一覧

| 用途 | 候補 | 備考 |
|---|---|---|
| 画面＋タッチ操作 | Sidecar (macOS/iPadOS 27) | 純正。同じ Apple ID・同じ Wi-Fi・Bluetooth オン・10 m 以内 |
| 画面＋タッチ操作 | Luna Display / Duet | 他社製。27 より前から指で操作できた |
| リモートデスクトップ | Screens 5 / Jump Desktop / RustDesk 等 | VNC や独自プロトコル。iPad のマイクは転送されない |
| キーボード・トラックパッド共有 | Universal Control | iPad に Magic Keyboard を付ければ Mac 側も操作できる。タッチ操作は不可 |
| マクロパッド | HotKeys 等 | ショートカットの送信だけなら十分 |
| iPad をマイクにする | Microphone Link ($3.99) | iPad 対応。Opus 48 kHz、低遅延モードで約 50 ms |
| iPad をマイクにする | WO Mic | iPad 対応。Mac 版クライアントが今の macOS で動くかは未確認 |
| iPad をマイクにする (自作寄り) | SonoBus + BlackHole | 無料・OSS。SonoBus の受信音を BlackHole に出し、Typeless の入力に BlackHole を選ぶ |

## Typeless 側の事実 (ローカル設定 `~/Library/Application Support/Typeless/app-settings.json` で確認)

- Electron 製のアプリ。マイク一覧は Chromium の `enumerateDevices()` で取得している (`deviceId` がハッシュ値、`kind: audioinput`)。そのため CoreAudio に入力デバイスとして登録されていれば、BlackHole のような仮想デバイスも選択肢に出るはず。
- 押している間だけ録音する push-to-talk のショートカットは `LeftCtrl+Fn` / `RightCtrl+Fn`。押すたびに録音の開始・停止を切り替える hands-free モードには、ショートカットが割り当てられていない。
- 自作のトリガーで遠隔起動するなら、Fn を含まないショートカットを hands-free モードに割り当てて、それを送るのが安全。合成した Fn キーのイベントが Typeless に届くかは検証していない。

## 自作する場合の方針 (調査時点の推奨。実際に採用した設計は design.md)

当時は BlackHole を使う前提だったが、仮想オーディオデバイスは端末全体を汚すため不採用になった。経緯は [design.md](design.md) にある。


- iPad: Swift / SwiftUI。音声は AVAudioEngine で取り込む。通信は Network.framework (Bonjour で相手を見つけ、TCP/UDP で送る)。
- Mac: Swift でメニューバー常駐アプリを作る。キー入力は CGEvent で送る (アクセシビリティ権限が必要)。仮想マイクはまず BlackHole を出力先にして始め、仕上げる段階で libASPL を使った AudioServerPlugIn を自作する。
- 画面転送 (必要な場合): ScreenCaptureKit + VideoToolbox (HEVC)。ただし Sidecar 27 で足りるなら作らない。

## 出典

- https://www.macrumors.com/2026/06/09/macos-27-brings-direct-touch-control-to-sidecar/
- https://www.macotakara.jp/mac_os_x/entry-51473.html
- https://support.apple.com/en-us/108046
- https://apps.apple.com/app/id6786537671
- https://changelog.jumpdesktop.com/microphone-forwarding-for-fluid-4CTeHS
- https://support.jumpdesktop.com/hc/en-us/community/posts/23604344950285-Microphone-pass-through
- https://apps.apple.com/ch/app/passmic/id6777161605
- https://audiorelay.net/docs/instructions/macos/use-your-phone-as-a-microphone-for-your-mac
