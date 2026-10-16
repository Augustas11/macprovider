// swift-tools-version: 6.0
// GLM-5.3-Flash native decode lab bench (epic #2029). Builds against the
// mlx-swift-lm fork (a revision at or after the provider's pin; newer ones
// only add lab parameters with unchanged defaults). It reads module internals,
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
            revision: "dcbf933369adc56d5152925f5a2d54e7f1f746be")
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
