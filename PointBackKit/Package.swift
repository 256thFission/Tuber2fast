// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PointBackKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PointBackKit", targets: ["PointBackKit"])
    ],
    targets: [
        .target(name: "PointBackKit"),
        .testTarget(name: "PointBackKitTests", dependencies: ["PointBackKit"])
    ]
)
