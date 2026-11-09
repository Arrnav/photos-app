// swift-tools-version: 6.0
import PackageDescription

// Backup: the persistent upload queue, exporting phone photos to files,
// the duplicate checks, and uploads on a background URLSession.
let package = Package(
    name: "Backup",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Backup", targets: ["Backup"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CloudCore"),
        .package(path: "../Persistence"),
        .package(path: "../Library"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "Backup", dependencies: ["Core", "CloudCore", "Persistence", "Library", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "BackupTests", dependencies: ["Backup", "CloudCore", "Persistence", "Library"]),
    ],
    swiftLanguageModes: [.v6]
)
