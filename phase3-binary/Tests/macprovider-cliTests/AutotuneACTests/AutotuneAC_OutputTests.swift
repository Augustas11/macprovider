import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class AutotuneACOutputTests: XCTestCase {
    /// AC-9: --apply is atomic, backs up, preserves non-owned config, and is idempotent; SPEC-013 lines 1463-1483.
    func testAC9ApplyIsAtomicAndBacksUpAndIsIdempotent() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let original = sampleConfig()
        try original.write(to: fixture.configURL, atomically: true, encoding: .utf8)
        let command = try fixture.command(["--apply", "--config", fixture.configURL.path])
        var deps = fixture.dependencies()
        deps.applyConfig = { recommendation, now, configPath in
            try ConfigApplier(configPath: URL(fileURLWithPath: configPath!)).apply(recommendation: recommendation, now: now)
        }

        try await command.run(dependencies: deps)

        let directory = fixture.configURL.deletingLastPathComponent()
        let firstBackup = directory.appendingPathComponent("config.yaml.bak-1781740800-0")
        XCTAssertEqual(try String(contentsOf: firstBackup), original)
        let firstPost = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(firstPost.contains("model: \(AutotuneCommand.defaultCandidates[0].modelID)"))
        XCTAssertTrue(firstPost.contains("kv_bits: 4"))
        XCTAssertTrue(firstPost.contains("max_context_override: 2000"))
        XCTAssertTrue(firstPost.contains("max_concurrency_override: 1"))
        XCTAssertEqual(nonOwnedLines(firstPost), nonOwnedLines(original))

        let loaded = try ConfigLoader.load(cli: CLIOverrides(configPath: fixture.configURL.path), environment: [:])
        XCTAssertEqual(loaded.model, AutotuneCommand.defaultCandidates[0].modelID)
        XCTAssertEqual(loaded.kvBitsOverride, 4)
        XCTAssertEqual(loaded.maxContextOverride, 2_000)
        XCTAssertEqual(loaded.maxConcurrencyOverride, 1)

        try await command.run(dependencies: deps)

        let secondBackup = directory.appendingPathComponent("config.yaml.bak-1781740800-1")
        XCTAssertEqual(try String(contentsOf: firstBackup), original)
        XCTAssertEqual(try String(contentsOf: secondBackup), firstPost)
        XCTAssertEqual(try String(contentsOf: fixture.configURL), firstPost)
    }

    /// AC-11: --json output preserves the documented schema fields and types; SPEC-013 lines 1494-1498.
    func testAC11JSONOutputSchemaStability() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command(["--json"])

        try await command.run(dependencies: fixture.dependencies())

        let root = try fixture.emittedJSONFromStdout()
        XCTAssertEqual(Set(root.keys), [
            "alternates",
            "db_path",
            "ended_at",
            "infeasible",
            "inputs",
            "machine",
            "recipe_hash",
            "recommendation",
            "run_id",
            "spec_version",
            "started_at",
        ])
        XCTAssertTrue(root["spec_version"] is String)
        XCTAssertTrue(root["run_id"] is String)
        XCTAssertTrue(root["started_at"] is String)
        XCTAssertTrue(root["ended_at"] is String)
        XCTAssertTrue(root["alternates"] is [String])
        XCTAssertTrue(root["infeasible"] is [[String: Any]])
        XCTAssertTrue(root["recipe_hash"] is String)
        XCTAssertTrue(root["db_path"] is String)

        let machine = try XCTUnwrap(root["machine"] as? [String: Any])
        XCTAssertEqual(Set(machine.keys), ["binary_version", "chip", "os_version", "ram_gb"])
        XCTAssertTrue(machine["ram_gb"] is Int)
        XCTAssertTrue(machine["chip"] is String)
        XCTAssertTrue(machine["os_version"] is String)
        XCTAssertTrue(machine["binary_version"] is String)

        let inputs = try XCTUnwrap(root["inputs"] as? [String: Any])
        XCTAssertEqual(Set(inputs.keys), [
            "candidate_models",
            "gate_ttft_ms",
            "stage1_replicates",
            "stage2_replicates",
            "target_context",
            "tps_tie_epsilon",
        ])
        XCTAssertTrue(inputs["candidate_models"] is [String])
        XCTAssertTrue(inputs["target_context"] is Int)
        XCTAssertTrue(inputs["stage1_replicates"] is Int)
        XCTAssertTrue(inputs["stage2_replicates"] is Int)
        XCTAssertTrue(inputs["gate_ttft_ms"] is Int)
        XCTAssertTrue(inputs["tps_tie_epsilon"] is Double)

        let recommendation = try XCTUnwrap(root["recommendation"] as? [String: Any])
        XCTAssertEqual(Set(recommendation.keys), [
            "knobs",
            "model",
            "replicates",
            "serve_command",
            "target_context",
            "tps_median",
            "ttft_p95_ms",
        ])
        let knobs = try XCTUnwrap(recommendation["knobs"] as? [String: Any])
        XCTAssertEqual(Set(knobs.keys), ["kv_bits", "max_concurrency_override", "max_context_override"])
        XCTAssertTrue(recommendation["model"] is String)
        XCTAssertTrue(recommendation["target_context"] is Int)
        XCTAssertTrue(recommendation["tps_median"] is Double)
        XCTAssertTrue(recommendation["ttft_p95_ms"] is Double)
        XCTAssertTrue(recommendation["replicates"] is Int)
        XCTAssertTrue(recommendation["serve_command"] is String)
    }

    /// AC-12: Recipe hashes are deterministic for same-machine same-recipe runs; SPEC-013 lines 1500-1525.
    func testAC12RecipeHashDeterminism() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var stage2Call = 0
        var deps = fixture.dependencies()
        deps.runStage2 = { request in
            stage2Call += 1
            let row = fixture.trial(
                runID: request.runID,
                stage: 2,
                model: request.selectedModel,
                fits: true,
                aggTPS: stage2Call == 1 ? 10 : 99,
                ttft: stage2Call == 1 ? 900 : 100,
                kvBits: 4,
                maxContext: request.targetContext,
                maxBatch: 1,
                kept: true
            )
            try request.db.insertTrial(row)
            return Stage2HillClimbResult(
                selectedModel: request.selectedModel,
                winningKnobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: request.targetContext),
                medianTPS: row.aggThroughputTPS!,
                p95TTFTMS: row.ttftP95MS!,
                replicates: request.stage2Replicates,
                cellTrials: [row]
            )
        }

        try await command.run(dependencies: deps)
        try await command.run(dependencies: deps)

        let hashes = try fixture.runRows().map(\.recipeHash)
        XCTAssertEqual(hashes.count, 2)
        XCTAssertEqual(hashes[0], hashes[1])
        let hash = try XCTUnwrap(hashes[0])
        XCTAssertTrue(matches(hash, pattern: #"^sha256:[0-9a-f]{64}$"#), hash)
    }

    private func sampleConfig() -> String {
        """
        # operator config
        coordinator_endpoint: https://coordinator.example
        model: old-model
        kv_bits: 8
        max_context_override: 1000
        max_concurrency_override: 2
        provider_token: keep-me
        log_path: /tmp/provider.log

        """
    }

    private func nonOwnedLines(_ text: String) -> [String] {
        let owned = ["model:", "kv_bits:", "max_context_override:", "max_concurrency_override:"]
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in !owned.contains { line.hasPrefix($0) } }
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
