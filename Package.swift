// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pendularium",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pendularium",
            path: "Sources/Pendularium",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PendulariumTests",
            dependencies: ["Pendularium"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
