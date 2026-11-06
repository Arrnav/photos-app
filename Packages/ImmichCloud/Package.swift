// swift-tools-version: 6.0
import PackageDescription

// Immich as a Cloud provider: implements CloudCore's protocols with the generated
// Immich client (ImmichAPI) and its sync stream (Sync).
let package = Package(
    name: "ImmichCloud",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ImmichCloud", targets: ["ImmichCloud"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CloudCore"),
        .package(path: "../ImmichAPI"),
        .package(path: "../Persistence"),
        .package(path: "../Sync"),
    ],
    targets: [
        .target(name: "ImmichCloud", dependencies: ["Core", "CloudCore", "ImmichAPI", "Persistence", "Sync"]),
        .testTarget(name: "ImmichCloudTests", dependencies: ["ImmichCloud", "CloudCore"]),
    ],
    swiftLanguageModes: [.v6]
)
