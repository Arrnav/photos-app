// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImmichAPI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ImmichAPI", targets: ["ImmichAPI"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CloudCore"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    ],
    targets: [
        // Sources/ImmichAPI/Generated is produced by Scripts/generate-api.sh and committed.
        .target(
            name: "ImmichAPI",
            dependencies: [
                "Core",
                "CloudCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(name: "ImmichAPITests", dependencies: ["ImmichAPI", "Core"]),
    ],
    swiftLanguageModes: [.v6]
)
