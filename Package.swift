// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PulseCore", platforms: [.macOS(.v14)], products: [], dependencies: [.package(path: "Vendor/RepMotion")], targets: [
    .target(name: "PulseCore", path: "App/Core"),
    .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore", .product(name: "RepMotionDetection", package: "RepMotion"), .product(name: "RepMotionCore", package: "RepMotion")], path: "Tests/PulseCoreTests")
])
