// swift-tools-version: 6.0
// TrainingCore: platform-independent domain logic for the "traningapp" project.
// Foundation only (no UIKit/AVFoundation/HealthKit) so it builds and tests on Linux.

import PackageDescription

let package = Package(
    name: "TrainingCore",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TrainingCore", targets: ["TrainingCore"]),
    ],
    targets: [
        .target(
            name: "TrainingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TrainingCoreTests",
            dependencies: ["TrainingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
