// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenMojiCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "OpenMojiCore", targets: ["OpenMojiCore"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "OpenMojiCore"),
        .testTarget(
            name: "OpenMojiCoreTests",
            dependencies: ["OpenMojiCore"]
        ),
    ]
)
