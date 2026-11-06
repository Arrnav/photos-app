// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCache",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MediaCache", targets: ["MediaCache"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CloudCore"),
    ],
    targets: [
        .target(name: "MediaCache", dependencies: ["Core", "CloudCore"]),
        .testTarget(name: "MediaCacheTests", dependencies: ["MediaCache", "CloudCore"]),
    ],
    swiftLanguageModes: [.v6]
)
