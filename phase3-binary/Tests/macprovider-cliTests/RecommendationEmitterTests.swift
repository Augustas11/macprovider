import Foundation
import XCTest
@testable import macprovider_cli

final class RecommendationEmitterTests: XCTestCase {
    func testTerminalBlockIncludesAllRequiredFields() throws {
        let emitted = try RecommendationEmitter().build(makeInputs())

        XCTAssertTrue(emitted.terminalBlock.contains("============================ RECOMMENDATION ============================"))
        XCTAssertTrue(emitted.terminalBlock.contains("model:           mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"))
        XCTAssertTrue(emitted.terminalBlock.contains("knobs:"))
        XCTAssertTrue(emitted.terminalBlock.contains("kv_bits:                    4"))
        XCTAssertTrue(emitted.terminalBlock.contains("max_concurrency_override:   1"))
        XCTAssertTrue(emitted.terminalBlock.contains("max_context_override:       4000"))
        XCTAssertTrue(emitted.terminalBlock.contains("tps_median:        2.1 tokens/sec"))
        XCTAssertTrue(emitted.terminalBlock.contains("ttft_p95:          19500 ms"))
        XCTAssertTrue(emitted.terminalBlock.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        XCTAssertTrue(emitted.terminalBlock.contains("macprovider-cli serve \\"))
        XCTAssertTrue(emitted.terminalBlock.contains("--model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"))
        XCTAssertTrue(emitted.terminalBlock.contains("--kv-bits 4"))
        XCTAssertTrue(emitted.terminalBlock.contains("--max-batch 1"))
        XCTAssertTrue(emitted.terminalBlock.contains("--max-context 4000"))
    }

    func testTerminalBlockEmitsKVBitsUnsetWhenNilWins() throws {
        var inputs = makeInputs()
        inputs.recommendation = RecommendationCore(
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2.1,
            ttftP95MS: 19_500,
            replicates: 3
        )

        let emitted = try RecommendationEmitter().build(inputs)

        XCTAssertTrue(emitted.terminalBlock.contains("kv_bits:                    unset"))
        XCTAssertFalse(emitted.serveCommand.contains("--kv-bits"))
        XCTAssertFalse(emitted.terminalBlock.contains("--kv-bits"))
    }

    func testTerminalBlockShowsNoRecommendationWhenRecommendationNil() throws {
        var inputs = makeInputs()
        inputs.recommendation = nil
        inputs.infeasible = [
            InfeasibleEntry(model: "A", rank: 1, reason: "provider exited"),
            InfeasibleEntry(model: "B", rank: 2, reason: "ttft exceeded"),
        ]

        let emitted = try RecommendationEmitter().build(inputs)

        XCTAssertTrue(emitted.terminalBlock.contains("========================== NO RECOMMENDATION =========================="))
        XCTAssertTrue(emitted.terminalBlock.contains("rank 1 A: provider exited"))
        XCTAssertTrue(emitted.terminalBlock.contains("rank 2 B: ttft exceeded"))
        XCTAssertFalse(emitted.terminalBlock.contains("serve command (copy-paste):"))
        XCTAssertEqual(emitted.serveCommand, "")
    }

    func testAlternatesListIsSliceAfterChosenModel() throws {
        var inputs = makeInputs(candidateModels: ["A", "B", "C", "D"])
        inputs.recommendation = RecommendationCore(
            model: "B",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )

        let emitted = try RecommendationEmitter().build(inputs)

        XCTAssertEqual(emitted.alternates, ["C", "D"])
    }

    func testAlternatesListEmptyWhenChosenIsSmallest() throws {
        var inputs = makeInputs(candidateModels: ["A", "B", "C", "D"])
        inputs.recommendation = RecommendationCore(
            model: "D",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )

        let emitted = try RecommendationEmitter().build(inputs)

        XCTAssertEqual(emitted.alternates, [])
    }

    func testJSONOutputMatchesSpec013Schema() throws {
        let emitted = try RecommendationEmitter().build(makeInputs())
        let root = try jsonObject(emitted.jsonString)

        XCTAssertEqual(root["spec_version"] as? String, "SPEC-013 v0.3")
        XCTAssertEqual(root["run_id"] as? String, "run-123")
        XCTAssertEqual(root["db_path"] as? String, "/tmp/autotune.sqlite")
        XCTAssertNotNil(root["recipe_hash"] as? String)

        let startedAt = try XCTUnwrap(root["started_at"] as? String)
        let endedAt = try XCTUnwrap(root["ended_at"] as? String)
        let iso8601 = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#
        XCTAssertNotNil(startedAt.range(of: iso8601, options: .regularExpression),
                        "started_at must be ISO 8601 with Z: \(startedAt)")
        XCTAssertNotNil(endedAt.range(of: iso8601, options: .regularExpression),
                        "ended_at must be ISO 8601 with Z: \(endedAt)")

        let machine = try XCTUnwrap(root["machine"] as? [String: Any])
        XCTAssertEqual(machine["ram_gb"] as? Int, 16)
        XCTAssertEqual(machine["chip"] as? String, "Apple M2")
        XCTAssertEqual(machine["os_version"] as? String, "macOS 26.3.1")
        XCTAssertEqual(machine["binary_version"] as? String, "1.4.0")
        XCTAssertEqual(Set(machine.keys), ["ram_gb", "chip", "os_version", "binary_version"])

        let inputsJSON = try XCTUnwrap(root["inputs"] as? [String: Any])
        XCTAssertEqual(inputsJSON["target_context"] as? Int, 4_000)
        XCTAssertEqual(inputsJSON["candidate_models"] as? [String], makeInputs().candidateModels)
        XCTAssertEqual(inputsJSON["stage1_replicates"] as? Int, 1)
        XCTAssertEqual(inputsJSON["stage2_replicates"] as? Int, 3)
        XCTAssertEqual(inputsJSON["gate_ttft_ms"] as? Int, 60_000)
        XCTAssertEqual(inputsJSON["tps_tie_epsilon"] as? Double, 0.02)
        XCTAssertEqual(Set(inputsJSON.keys), [
            "target_context", "candidate_models", "stage1_replicates",
            "stage2_replicates", "gate_ttft_ms", "tps_tie_epsilon",
        ])

        let recommendation = try XCTUnwrap(root["recommendation"] as? [String: Any])
        XCTAssertEqual(recommendation["model"] as? String,
                       "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(recommendation["target_context"] as? Int, 4_000)
        XCTAssertEqual(recommendation["tps_median"] as? Double, 2.1)
        XCTAssertEqual(recommendation["ttft_p95_ms"] as? Double, 19_500)
        XCTAssertEqual(recommendation["replicates"] as? Int, 3)
        XCTAssertEqual(recommendation["serve_command"] as? String, emitted.serveCommand)
        XCTAssertEqual(Set(recommendation.keys), [
            "model", "target_context", "knobs", "tps_median",
            "ttft_p95_ms", "replicates", "serve_command",
        ])

        let knobs = try XCTUnwrap(recommendation["knobs"] as? [String: Any])
        XCTAssertEqual(knobs["kv_bits"] as? Int, 4)
        XCTAssertEqual(knobs["max_concurrency_override"] as? Int, 1)
        XCTAssertEqual(knobs["max_context_override"] as? Int, 4_000)
        XCTAssertNil(knobs["max_batch"])
        XCTAssertNil(knobs["max_context"])
        XCTAssertEqual(Set(knobs.keys), ["kv_bits", "max_concurrency_override", "max_context_override"])

        let alternates = try XCTUnwrap(root["alternates"] as? [String])
        XCTAssertEqual(alternates, [
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
        ])

        let infeasible = try XCTUnwrap(root["infeasible"] as? [[String: Any]])
        XCTAssertEqual(infeasible.count, 1)
        XCTAssertEqual(infeasible[0]["model"] as? String,
                       "mlx-community/Qwen2.5-32B-Instruct-4bit")
        XCTAssertEqual(infeasible[0]["rank"] as? Int, 1)
        XCTAssertEqual(infeasible[0]["reason"] as? String, "provider exited rc=137")
        XCTAssertEqual(Set(infeasible[0].keys), ["model", "rank", "reason"])
    }

    func testRecipeHashIsNilWhenRecommendationIsNil() throws {
        var inputs = makeInputs()
        inputs.recommendation = nil

        let emitted = try RecommendationEmitter().build(inputs)
        let root = try jsonObject(emitted.jsonString)

        XCTAssertNil(emitted.recipeHash)
        XCTAssertTrue(root["recipe_hash"] is NSNull,
                      "JSON recipe_hash must be null when recommendation is nil")
    }

    func testJSONOutputRecommendationFieldIsNullWhenNotSelected() throws {
        var inputs = makeInputs()
        inputs.recommendation = nil

        let emitted = try RecommendationEmitter().build(inputs)
        let root = try jsonObject(emitted.jsonString)

        XCTAssertTrue(root["recommendation"] is NSNull)
    }

    func testJSONOutputRecipeHashFormat() throws {
        let emitted = try RecommendationEmitter().build(makeInputs())
        let pattern = #"^sha256:[0-9a-f]{64}$"#
        let recipeHash = try XCTUnwrap(emitted.recipeHash)
        XCTAssertNotNil(recipeHash.range(of: pattern, options: .regularExpression))
        XCTAssertEqual(recipeHash, recipeHash.lowercased())
    }

    func testRecipeHashMatchesReferenceVector() throws {
        let inputs = makeReferenceVectorInputs()

        let emitted = try RecommendationEmitter().build(inputs)

        XCTAssertEqual(
            emitted.recipeHash,
            "sha256:eb5f8f90c09c2bbcec0dca6f42c203c25a7a8d403a734c6a81379b14ad702f9d"
        )
    }

    func testRecipeHashIgnoresObservationFields() throws {
        let first = makeInputs()
        var second = first
        second.runID = "different-run"
        second.startedAt = date("2026-06-18T14:00:00Z")
        second.endedAt = date("2026-06-18T14:10:00Z")
        second.recommendation = RecommendationCore(
            model: first.recommendation!.model,
            targetContext: first.recommendation!.targetContext,
            knobs: first.recommendation!.knobs,
            tpsMedian: 99,
            ttftP95MS: 1,
            replicates: 99
        )

        let firstHash = try RecommendationEmitter().build(first).recipeHash
        let secondHash = try RecommendationEmitter().build(second).recipeHash

        XCTAssertEqual(firstHash, secondHash)
    }

    func testRecipeHashSensitiveToMachineRAM() throws {
        let first = makeInputs()
        var second = first
        second.machine.ramGB = 8

        let firstHash = try RecommendationEmitter().build(first).recipeHash
        let secondHash = try RecommendationEmitter().build(second).recipeHash

        XCTAssertNotEqual(firstHash, secondHash)
    }

    func testRecipeHashSensitiveToBinaryVersion() throws {
        let first = makeInputs()
        var second = first
        second.machine.binaryVersion = "1.4.1"

        let firstHash = try RecommendationEmitter().build(first).recipeHash
        let secondHash = try RecommendationEmitter().build(second).recipeHash

        XCTAssertNotEqual(firstHash, secondHash)
    }

    func testRecipeHashOmitsKVBitsCorrectlyWhenNilWins() throws {
        var first = makeInputs()
        first.recommendation = RecommendationCore(
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            targetContext: 4_000,
            knobs: WinningKnobs(kvBits: nil, maxBatch: 1, maxContext: 4_000),
            tpsMedian: 2,
            ttftP95MS: 10,
            replicates: 3
        )
        var second = first
        second.runID = "other"
        second.recommendation = RecommendationCore(
            model: first.recommendation!.model,
            targetContext: first.recommendation!.targetContext,
            knobs: first.recommendation!.knobs,
            tpsMedian: 3,
            ttftP95MS: 11,
            replicates: 3
        )

        let canonical = try RFC8785JCS.canonicalString(RecommendationEmitter.recipeHashInput(first))

        XCTAssertTrue(canonical.contains(#""kv_bits":null"#), canonical)
        XCTAssertFalse(canonical.contains(#""kv_bits":"unset""#), canonical)
        XCTAssertEqual(
            try RecommendationEmitter().build(first).recipeHash,
            try RecommendationEmitter().build(second).recipeHash
        )
    }

    private func makeInputs(
        candidateModels: [String] = [
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
        ]
    ) -> RecommendationInputs {
        RecommendationInputs(
            specVersion: "SPEC-013 v0.3",
            runID: "run-123",
            startedAt: date("2026-06-18T12:34:56Z"),
            endedAt: date("2026-06-18T13:01:22Z"),
            machine: MachineFingerprint(
                ramGB: 16,
                chip: "Apple M2",
                osVersion: "macOS 26.3.1",
                binaryVersion: "1.4.0"
            ),
            targetContext: 4_000,
            candidateModels: candidateModels,
            stage1Replicates: 1,
            stage2Replicates: 3,
            gateTTFTMS: 60_000,
            tpsTieEpsilon: 0.02,
            recommendation: RecommendationCore(
                model: candidateModels[0],
                targetContext: 4_000,
                knobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 4_000),
                tpsMedian: 2.1,
                ttftP95MS: 19_500,
                replicates: 3
            ),
            infeasible: [
                InfeasibleEntry(model: "mlx-community/Qwen2.5-32B-Instruct-4bit", rank: 1, reason: "provider exited rc=137")
            ],
            dbPath: "/tmp/autotune.sqlite"
        )
    }

    private func makeReferenceVectorInputs() -> RecommendationInputs {
        RecommendationInputs(
            specVersion: "SPEC-013 v0.3",
            runID: "ignored",
            startedAt: date("2026-06-18T12:34:56Z"),
            endedAt: date("2026-06-18T13:01:22Z"),
            machine: MachineFingerprint(
                ramGB: 16,
                chip: "Apple M2",
                osVersion: "ignored",
                binaryVersion: "1.4.0"
            ),
            targetContext: 4_000,
            candidateModels: [
                "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                "mlx-community/Llama-3.2-3B-Instruct-4bit",
            ],
            stage1Replicates: 1,
            stage2Replicates: 3,
            gateTTFTMS: 60_000,
            tpsTieEpsilon: 0.02,
            recommendation: RecommendationCore(
                model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                targetContext: 4_000,
                knobs: WinningKnobs(kvBits: 4, maxBatch: 1, maxContext: 4_000),
                tpsMedian: 2.1,
                ttftP95MS: 19_500,
                replicates: 3
            ),
            infeasible: [],
            dbPath: "ignored"
        )
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
