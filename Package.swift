// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrameBoost",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "FrameBoostCore", targets: ["FrameBoostCore"])
    ],
    targets: [
        .target(name: "FrameBoostCore", path: "FrameBoostCore"),
        .testTarget(
            name: "FrameBoostCoreTests",
            dependencies: ["FrameBoostCore"],
            path: "FrameBoostCoreTests"
        )
    ]
)
