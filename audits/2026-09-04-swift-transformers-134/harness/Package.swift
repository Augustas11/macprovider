// swift-tools-version:5.9
import PackageDescription

// swift-transformers exact version is injected by the runner via
// TOKPARITY_TRANSFORMERS_VERSION so the same source builds at 1.0.0 and 1.3.4.
let transformersVersion = Context.environment["TOKPARITY_TRANSFORMERS_VERSION"] ?? "1.3.4"

let package = Package(
    name: "tokparity",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: Version(stringLiteral: transformersVersion)
        )
    ],
    targets: [
        .executableTarget(
            name: "tokparity",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        )
    ]
)
