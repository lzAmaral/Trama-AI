// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trama",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Trama", targets: ["TramaApp"]),
        .library(name: "TramaCore", targets: ["TramaCore"])
    ],
    targets: [
        .target(name: "TramaCore"),
        .executableTarget(name: "TramaApp", dependencies: ["TramaCore"]),
        .testTarget(name: "TramaCoreTests", dependencies: ["TramaCore"])
    ]
)
