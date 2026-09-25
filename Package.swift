// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.4", traits: []),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "MurmurApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
