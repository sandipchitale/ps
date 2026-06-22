// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ps",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ps", targets: ["ps"])
    ],
    targets: [
        .executableTarget(
            name: "ps",
            path: "Sources"
        )
    ]
)
