// swift-tools-version: 6.0
// RockyCore: platform-independent domain logic for the Rocky project.
// Foundation only (no UIKit/AVFoundation/HealthKit) so it builds and tests on Linux.

import PackageDescription

let package = Package(
    name: "RockyCore",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RockyCore", targets: ["RockyCore"]),
    ],
    targets: [
        .target(
            name: "RockyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RockyCoreTests",
            dependencies: ["RockyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
