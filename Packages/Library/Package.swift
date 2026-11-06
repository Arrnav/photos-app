// swift-tools-version: 6.0
import PackageDescription

// The phone's own photo library (PhotoKit): indexing into the database, iCloud
// identities, and checksums computed exactly like the official Immich app (PLAN.md D5).
let package = Package(
    name: "Library",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Library", targets: ["Library"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Persistence"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "Library", dependencies: ["Core", "Persistence", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Persistence"]),
    ],
    swiftLanguageModes: [.v6]
)
