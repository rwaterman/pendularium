// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pendularium",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pendularium",
            path: "Sources/Pendularium"
        )
    ]
)
