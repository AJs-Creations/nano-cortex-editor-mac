// swift-tools-version:6.0
// NanoCore: the Nano Cortex Bluetooth protocol (framing, protobuf-style codec,
// message builders and parsers, device state) with no UI and no CoreBluetooth
// dependency, so it is testable headless against recorded packets.
import PackageDescription

let package = Package(
    name: "NanoCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NanoCore", targets: ["NanoCore"])],
    targets: [
        .target(name: "NanoCore"),
        .testTarget(name: "NanoCoreTests", dependencies: ["NanoCore"]),
    ]
)
