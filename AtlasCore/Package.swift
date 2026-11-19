// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtlasCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "atlas-cli", targets: ["AtlasCLI"]),
    ],
    dependencies: [
        .package(path: "../../hominem-swift"),
    ],
    targets: [
        .target(
            name: "AtlasCore",
            dependencies: [
                .product(name: "WalksCore", package: "hominem-swift"),
                .product(name: "PlaceCore", package: "hominem-swift"),
                .product(name: "GeoCore", package: "hominem-swift"),
                .product(name: "UtilityCore", package: "hominem-swift"),
                .product(name: "FlightCore", package: "hominem-swift"),
                .product(name: "ParcelCore", package: "hominem-swift"),
                .product(name: "TransitCore", package: "hominem-swift"),
            ],
            path: "Sources/AtlasCore"
        ),
        .executableTarget(name: "AtlasCLI", dependencies: ["AtlasCore"], path: "Sources/AtlasCLI"),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore"], path: "Tests/AtlasCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)