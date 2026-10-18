derived_data := "build/DerivedData"
# Mac の Host と iPad アプリのビルドが一致しないときに通知するため、ビルド元のコミットを埋め込む
commit := `git describe --always --dirty 2>/dev/null || echo unknown`

# project.yml から PadBridge.xcodeproj を生成する
generate:
    nix develop --command xcodegen generate

# アプリのアイコンを再生成する (Scripts/AppIcon.swift の描画を iPad と Mac のアセットカタログに書き出す)
icon:
    swift Scripts/AppIcon.swift Apps/Pad/Assets.xcassets/AppIcon.appiconset Apps/Host/Assets.xcassets/AppIcon.appiconset

# 共通ライブラリ (通信・映像・入力) のテスト
test:
    swift test --package-path Packages/PadBridgeKit

# 変更後の確認をまとめて行う: 共通ライブラリのテスト (macOS・Thread Sanitizer・iOS シミュレータ) と、Mac 側と iPad アプリのビルド (コードの警告があれば失敗。前回のビルドが残っていると変更していないファイルの警告が出ないので、毎回クリーンビルドする)
check: generate test test-tsan test-ios
    Scripts/check-warnings.sh xcodebuild -project PadBridge.xcodeproj -scheme PadBridgeHost -configuration Debug -derivedDataPath build/CheckDerivedData PADBRIDGE_COMMIT={{commit}} clean build
    Scripts/check-warnings.sh xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination generic/platform=iOS -derivedDataPath build/CheckDerivedData PADBRIDGE_COMMIT={{commit}} clean build

# 共通ライブラリのテストを Thread Sanitizer 付きで実行する (送受信やサウンドの再生など、複数のスレッドから使う部品のデータ競合を検出する)
test-tsan:
    swift test --package-path Packages/PadBridgeKit --scratch-path build/KitTestsTSan --sanitize=thread

# 共通ライブラリのテストを iOS シミュレータで実行する (Opus のデコードなど、iPad で使う部品が iOS でも動くかを確認する)
test-ios simulator="iPad Air 11-inch (M4)":
    cd Packages/PadBridgeKit && xcodebuild test -scheme PadBridgeKit -destination "platform=iOS Simulator,name={{simulator}}" -derivedDataPath ../../build/KitTestsIOS

# Mac 側の常駐アプリをビルドする
build-host: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridgeHost -configuration Debug -derivedDataPath {{derived_data}} -allowProvisioningUpdates PADBRIDGE_COMMIT={{commit}} build

# Mac 側の常駐アプリをビルドして起動する
run-host: build-host
    open "{{derived_data}}/Build/Products/Debug/PadBridge Host.app"

# 起動中の Mac 側の常駐アプリを新しいビルドに更新する。Typeless が音声入力中のときと、iPad が接続中のときは更新しない
deploy-host: build-host
    Scripts/deploy-host.sh "{{derived_data}}/Build/Products/Debug/PadBridge Host.app"

# iPad アプリを実機向けにビルドする
build-pad: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination generic/platform=iOS -derivedDataPath {{derived_data}} -allowProvisioningUpdates PADBRIDGE_COMMIT={{commit}} build

# iPad アプリをシミュレータ向けにビルドする (署名なし)
build-pad-simulator: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath {{derived_data}} build

# 接続中の実機に iPad アプリをインストールする (devicectl list devices で ID を確認する)
install-pad device: build-pad
    xcrun devicectl device install app --device {{device}} "{{derived_data}}/Build/Products/Debug-iphoneos/PadBridge.app"

# iPad アプリを新しいビルドに更新する。インストールするとアプリが終了するので、iPad が Host に接続中の間はインストールしない
deploy-pad device: build-pad
    if Scripts/pad-connected.sh; then echo "iPad が接続中のため、インストールを中止しました" >&2; exit 1; fi
    xcrun devicectl device install app --device {{device}} "{{derived_data}}/Build/Products/Debug-iphoneos/PadBridge.app"
