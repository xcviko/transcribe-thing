// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "transcribe-thing",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "transcribe-thing", targets: ["transcribe-thing"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.4", traits: []),
    ],
    targets: [
        .target(
            name: "TranscribeThing",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "transcribe-thing",
            dependencies: ["TranscribeThing"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscribeThingTests",
            dependencies: ["TranscribeThing"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
