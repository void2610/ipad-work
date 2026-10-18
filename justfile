derived_data := "build/DerivedData"

# project.yml から PadBridge.xcodeproj を作る
generate:
    nix develop --command xcodegen generate

# アプリのアイコンを描き直す (Scripts/AppIcon.swift の絵を iPad と Mac のアセットカタログに書き出す)
icon:
    swift Scripts/AppIcon.swift Apps/Pad/Assets.xcassets/AppIcon.appiconset Apps/Host/Assets.xcassets/AppIcon.appiconset

# 共通ライブラリ (通信・映像・入力) のテスト
test:
    swift test --package-path Packages/PadBridgeKit

# 共通ライブラリのテストを iOS のシミュレータで走らせる (Opus の復号など、iPad で使う部品が iOS でも動くかを確かめる)
test-ios simulator="iPad Air 11-inch (M4)":
    cd Packages/PadBridgeKit && xcodebuild test -scheme PadBridgeKit -destination "platform=iOS Simulator,name={{simulator}}" -derivedDataPath ../../build/KitTestsIOS

# Mac 側の常駐アプリをビルドする
build-host: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridgeHost -configuration Debug -derivedDataPath {{derived_data}} -allowProvisioningUpdates build

# Mac 側の常駐アプリをビルドして起動する
run-host: build-host
    open "{{derived_data}}/Build/Products/Debug/PadBridge Host.app"

# 動いている Mac 側の常駐アプリを新しいビルドに入れ替える。Typeless が聞き取り中のときと、iPad がつながっているときは入れ替えない
deploy-host: build-host
    Scripts/deploy-host.sh "{{derived_data}}/Build/Products/Debug/PadBridge Host.app"

# iPad アプリを実機向けにビルドする
build-pad: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination generic/platform=iOS -derivedDataPath {{derived_data}} -allowProvisioningUpdates build

# iPad アプリをシミュレータ向けにビルドする (署名なし)
build-pad-simulator: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath {{derived_data}} build

# 接続中の実機に iPad アプリを入れる (devicectl list devices で ID を確認する)
install-pad device: build-pad
    xcrun devicectl device install app --device {{device}} "{{derived_data}}/Build/Products/Debug-iphoneos/PadBridge.app"
