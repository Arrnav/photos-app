// swift-tools-version: 6.0
import PackageDescription

/// Pure geometry for the photo grid (frames, visible ranges, pinch-zoom
/// interpolation). No UIKit, so it is unit-tested on macOS.
let package = Package(
    name: "GridGeometry",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GridGeometry", targets: ["GridGeometry"]),
    ],
    targets: [
        .target(name: "GridGeometry"),
        .testTarget(name: "GridGeometryTests", dependencies: ["GridGeometry"]),
    ],
    swiftLanguageModes: [.v6]
)
