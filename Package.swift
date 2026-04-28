// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Khons",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Khons",
            path: "Sources/Khons"
        ),
    ]
)
