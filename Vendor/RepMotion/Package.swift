// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RepMotion",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RepMotionCore", targets: ["RepMotionCore"]),
        .library(name: "RepMotionDetection", targets: ["RepMotionDetection"]),
        .library(name: "RepMotionCapture", targets: ["RepMotionCapture"]),
    ],
    targets: [
        .target(
            name: "RepMotionCore"
        ),
        .target(
            name: "RepMotionDetection",
            dependencies: ["RepMotionCore"]
        ),
        .target(
            name: "RepMotionCapture",
            dependencies: ["RepMotionCore"]
        ),
        .testTarget(
            name: "RepMotionCoreTests",
            dependencies: ["RepMotionCore"]
        ),
        .testTarget(
            name: "RepMotionDetectionTests",
            dependencies: ["RepMotionDetection"]
        ),
        .testTarget(
            name: "RepMotionCaptureTests",
            dependencies: ["RepMotionCapture"]
        ),
    ]
)
