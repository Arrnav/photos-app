// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../ImmichAPI"),
        .package(path: "../Persistence"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.3"),
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: [
                "Core", "ImmichAPI", "Persistence",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: [
                "Sync", "ImmichAPI", "Persistence",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
