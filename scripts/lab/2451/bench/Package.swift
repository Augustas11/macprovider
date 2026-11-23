// swift-tools-version: 6.0
// #2451 tile microbench (scripts/lab/2451/tiles.py has the method). Builds against a local
// mlx-swift tree whose Source/Cmlx/mlx is the fork branch macprovider/2451-tile-variants: the
// launcher ships mlx-swift 12d26ef6c with that core and sets TILE_BENCH_MLX_SWIFT to it.
//   TILE_BENCH_MLX_SWIFT=<dir> swift build -c release --build-system native
// The dependency directory must be named mlx-swift (SwiftPM names a path package after its
// directory). Place the provider's mlx.metallib next to the TileBench binary (MLX JIT-compiles the
// quantized kernels; the metallib serves the rest).
import Foundation
import PackageDescription

let mlxSwift = ProcessInfo.processInfo.environment["TILE_BENCH_MLX_SWIFT"] ?? "mlx-swift"

let package = Package(
    name: "TileBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: mlxSwift)],
    targets: [
        .executableTarget(
            name: "TileBench",
            dependencies: [.product(name: "MLX", package: "mlx-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
