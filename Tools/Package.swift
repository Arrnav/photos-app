// swift-tools-version: 6.0
// Developer tools only; not linked into the app.
import PackageDescription

let package = Package(
    name: "Tools",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.2"),
    ]
)
