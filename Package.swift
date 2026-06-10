// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "openflock",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlockCore", targets: ["FlockCore"]),
        .executable(name: "OpenFlock", targets: ["OpenFlockApp"]),
    ],
    targets: [
        .target(name: "FlockCore"),
        .executableTarget(name: "OpenFlockApp", dependencies: ["FlockCore"]),
        .testTarget(name: "FlockCoreTests", dependencies: ["FlockCore"]),
    ]
)
