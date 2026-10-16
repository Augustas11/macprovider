// swift-tools-version: 6.0
// GLM-5.3-Flash native decode lab bench (epic #2029). Builds against the
// mlx-swift-lm fork revision the provider pins; it reads module internals,
// so build with testing enabled:
//   swift build -c release --build-system native -Xswiftc -enable-testing
// and place the core's mlx.metallib next to .build/release/GLMBench.
import PackageDescription

let package = Package(
    name: "GLMBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/Augustas11/mlx-swift-lm.git",
            revision: "e2c8ed2a48c72e0b414e357513b789b12a42ebd1")
    ],
    targets: [
        .executableTarget(
            name: "GLMBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
