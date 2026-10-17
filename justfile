derived_data := "build/DerivedData"

# project.yml から PadBridge.xcodeproj を作る
generate:
    nix develop --command xcodegen generate

# 共通ライブラリ (通信・映像・入力) のテスト
test:
    swift test --package-path Packages/PadBridgeKit

# Mac 側の常駐アプリをビルドする
build-host: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridgeHost -configuration Debug -derivedDataPath {{derived_data}} -allowProvisioningUpdates build

# Mac 側の常駐アプリをビルドして起動する
run-host: build-host
    open "{{derived_data}}/Build/Products/Debug/PadBridge Host.app"

# 実際の Host を相手に、iPad 役のクライアントで通しの動作を確かめる (数秒間、カーソルと前面の窓を使う)
e2e: build-host
    swiftc -swift-version 5 -O -o build/e2e Packages/PadBridgeKit/Sources/PadBridgeKit/*/*.swift Tools/E2E/main.swift
    ./Tools/E2E/run.sh

# iPad アプリを実機向けにビルドする
build-pad: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination generic/platform=iOS -derivedDataPath {{derived_data}} -allowProvisioningUpdates build

# iPad アプリをシミュレータ向けにビルドする (署名なし)
build-pad-simulator: generate
    xcodebuild -project PadBridge.xcodeproj -scheme PadBridge -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath {{derived_data}} build

# 接続中の実機に iPad アプリを入れる (devicectl list devices で ID を確認する)
install-pad device: build-pad
    xcrun devicectl device install app --device {{device}} "{{derived_data}}/Build/Products/Debug-iphoneos/PadBridge.app"
