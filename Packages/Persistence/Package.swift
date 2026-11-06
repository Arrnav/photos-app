// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ],
    swiftLanguageModes: [.v6]
)
