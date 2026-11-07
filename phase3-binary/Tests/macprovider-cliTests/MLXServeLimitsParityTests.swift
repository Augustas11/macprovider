import XCTest
@testable import macprovider_cli
@testable import MacProviderCore

/// SPEC-038 FR-CB2 (v0.3.36): commands that load a model outside `serve`
/// resolve the MLX cache bound serve resolves for the same config, and serve's
/// bound is never unset.
final class MLXServeLimitsParityTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let mib = 1024 * 1024

    func testServeCacheLimitIsBoundedWhenTheConfigOmitsIt() {
        for ram in [UInt64(0), 4 * gib, 8 * gib, 8 * gib + 1, 16 * gib, 64 * gib, 256 * gib, UInt64.max] {
            for model in [nil, "zai-org/glm-5.3-flash", "liquidai/lfm2.5-24b-a2b"] as [String?] {
                let bytes = MLXMemoryLimit.serveCacheLimitBytes(modelID: model, configuredMB: nil, physicalMemoryBytes: ram)
                XCTAssertNotNil(bytes, "ram \(ram) model \(model ?? "nil")")
                XCTAssertLessThanOrEqual(bytes ?? .max, 2048 * mib, "ram \(ram) model \(model ?? "nil")")
            }
        }
        XCTAssertEqual(
            MLXMemoryLimit.serveCacheLimitBytes(modelID: nil, configuredMB: nil, physicalMemoryBytes: 256 * gib),
            2048 * mib)
    }

    func testBenchCommandsResolveServesCacheLimitForTheSameConfig() async throws {
        let ram = ProcessInfo.processInfo.physicalMemory
        for configured in [nil, 0, 512, 4096] as [Int?] {
            // serve: the config file value, through the runtime's load selection.
            let yaml = configured.map { "mlx_cache_limit_mb: \($0)\n" } ?? ""
            let config = try ConfigLoader.load(
                cli: CLIOverrides(), environment: [:], fileExists: { _ in true }, readFile: { _ in yaml })
            XCTAssertEqual(config.mlxCacheLimitMB, configured)
            let runtime = try await ModelRuntime(modelID: nil, mlxCacheLimitMB: config.mlxCacheLimitMB)
            let serveMB = await runtime.mlxCacheLimitMBForLoading

            // The same setting passed to the bench commands.
            let flag = configured.map { ["--mlx-cache-limit-mb", String($0)] } ?? []
            let msb = try MSBThroughputCommand.parse(["--model", "/nonexistent-fixture"] + flag)
            let parity = try GLMParityCommand.parse(["--model-dir", "/nonexistent-fixture", "--oracle", "o.json"] + flag)
            XCTAssertEqual(msb.mlxCacheLimitMB, configured)
            XCTAssertEqual(parity.mlxCacheLimitMB, configured)
            let benchRuntime = try await ModelRuntime(modelID: nil, mlxCacheLimitMB: msb.mlxCacheLimitMB)
            let benchMB = await benchRuntime.mlxCacheLimitMBForLoading
            XCTAssertEqual(benchMB, serveMB, "configured \(configured.map(String.init) ?? "nil")")

            // Commands that load outside ModelRuntime use the shared helper.
            for model in [nil, "zai-org/glm-5.3-flash", "liquidai/lfm2.5-24b-a2b"] as [String?] {
                let serveBytes = serveMB.map {
                    ModelRuntime.modelScopedMLXCacheLimitBytes(modelID: model, baselineBytes: $0 * mib)
                }
                XCTAssertEqual(
                    MLXMemoryLimit.serveCacheLimitBytes(
                        modelID: model, configuredMB: configured, physicalMemoryBytes: ram),
                    serveBytes, "configured \(configured.map(String.init) ?? "nil") model \(model ?? "nil")")
            }
        }
    }
}
