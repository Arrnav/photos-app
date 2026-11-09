// swift-tools-version: 6.0
import PackageDescription

// The provider-neutral layer between the app and a photo server ("Cloud"). The UI
// talks only to these protocols and models; Immich is one implementation (ImmichCloud).
let package = Package(
    name: "CloudCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CloudCore", targets: ["CloudCore"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(name: "CloudCore", dependencies: ["Core", "Persistence"]),
        .testTarget(name: "CloudCoreTests", dependencies: ["CloudCore", "Core"]),
    ],
    swiftLanguageModes: [.v6]
)
