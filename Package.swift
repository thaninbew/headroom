// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
        .executable(name: "headroom-hook", targets: ["HeadroomHook"]),
        .executable(name: "headroomctl", targets: ["HeadroomCLI"]),
        .executable(name: "Headroom", targets: ["HeadroomApp"]),
    ],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "HeadroomHook", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "HeadroomCLI", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
