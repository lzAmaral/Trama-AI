// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trama",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Trama", targets: ["TramaApp"]),
        .library(name: "TramaCore", targets: ["TramaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5")
    ],
    targets: [
        .target(name: "TramaCore"),
        .executableTarget(name: "TramaApp", dependencies: ["TramaCore", "SwiftTerm"]),
        .testTarget(name: "TramaCoreTests", dependencies: ["TramaCore"])
    ]
)
