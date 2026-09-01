// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrameBoost",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FrameBoostCore", targets: ["FrameBoostCore"])
    ],
    targets: [
        .target(name: "FrameBoostCore", path: "FrameBoostCore")
    ]
)
