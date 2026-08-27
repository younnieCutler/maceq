// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacEQ",
    defaultLocalization: "ko",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "maceq",
            path: "Sources/MacEQ",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "MacEQTests",
            dependencies: ["maceq"],
            path: "Tests/MacEQTests"
        )
    ]
)
