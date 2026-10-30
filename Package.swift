// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Totality",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TotalityCore", targets: ["TotalityCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.9.1"),
    ],
    targets: [
        .target(name: "TotalityCore", dependencies: [
            .product(name: "Sodium", package: "swift-sodium"),
        ]),
        .testTarget(name: "TotalityCoreTests", dependencies: ["TotalityCore"]),
    ]
)
