// swift-tools-version: 6.0
// DisplayVolume — software volume control for fixed-volume external displays.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let package = Package(
    name: "DisplayVolume",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "DisplayVolumeKit", targets: ["DisplayVolumeKit"]),
        .executable(name: "DisplayVolumeApp", targets: ["DisplayVolumeApp"]),
    ],
    targets: [
        // Tiny C target providing real-time-safe atomics (stdatomic.h) usable
        // from Swift audio callbacks without third-party dependencies.
        .target(name: "CAtomics"),
        .target(
            name: "DisplayVolumeKit",
            dependencies: ["CAtomics"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "DisplayVolumeApp",
            dependencies: ["DisplayVolumeKit"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DisplayVolumeKitTests",
            dependencies: ["DisplayVolumeKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
