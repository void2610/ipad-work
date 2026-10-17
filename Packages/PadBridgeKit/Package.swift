// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PadBridgeKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PadBridgeKit", targets: ["PadBridgeKit"]),
    ],
    targets: [
        .target(name: "PadBridgeKit"),
        .testTarget(name: "PadBridgeKitTests", dependencies: ["PadBridgeKit"]),
    ]
)
