// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotosAppUI",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "PhotosAppUI", targets: ["PhotosAppUI"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CloudCore"),
        .package(path: "../Persistence"),
        .package(path: "../Library"),
        .package(path: "../Backup"),
        .package(path: "../MediaCache"),
        .package(path: "../GridGeometry"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "PhotosAppUI",
            dependencies: [
                "Core", "CloudCore", "Persistence", "Library", "Backup", "MediaCache", "GridGeometry",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
