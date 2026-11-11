// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtlasCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "atlas-cli", targets: ["AtlasCLI"]),
    ],
    targets: [
        .target(name: "AtlasCore", path: "Sources/AtlasCore"),
        .executableTarget(name: "AtlasCLI", dependencies: ["AtlasCore"], path: "Sources/AtlasCLI"),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"], path: "Tests/AtlasCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)