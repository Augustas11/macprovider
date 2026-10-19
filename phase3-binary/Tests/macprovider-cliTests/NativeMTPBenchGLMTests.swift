#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

/// `native-mtp-bench` on a GLM-5.3-Flash fixture: the MTP layer is embedded
/// in the target (`checkpoint_mtp`), so the fixture has no `mtp/` directory,
/// and the family's greedy-only profile and one-row bound are checked before
/// any model load.
final class NativeMTPBenchGLMTests: XCTestCase {
    private static let glmPolicyURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/research/spec048-r015/glm53-flash-r015-v2/policy.json")

    func testGLMFixtureResolvesItsMTPArtifactToTheTarget() throws {
        let root = try fixtureRoot(config: GLM5NextPagedKVWiringTests.config())
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = NativeMTPBenchFixtureLayout.resolve(root: root)
        XCTAssertEqual(layout.family, .glm5Next)
        XCTAssertEqual(layout.mtpDirectory.lastPathComponent, "target")
        XCTAssertEqual(layout.mtpDirectory, layout.targetDirectory)
    }

    func testQwenFixtureKeepsItsSeparateMTPDirectory() throws {
        let root = try fixtureRoot(config: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = NativeMTPBenchFixtureLayout.resolve(root: root)
        XCTAssertEqual(layout.family, .qwen35)
        XCTAssertEqual(layout.mtpDirectory.lastPathComponent, "mtp")
    }

    func testFrozenGLMPolicyLoadsAndFitsTheFamily() throws {
        let policy = try NativeMTPBenchPolicy.load(from: Self.glmPolicyURL)
        XCTAssertEqual(
            policy.matrixCells.map(\.id),
            ["s1-p1536-o128", "s1-p1536-o512", "s1-p4096-o128", "s1-p4096-o512", "s2-p1536-o512", "s4-p1536-o512"]
        )
        XCTAssertEqual(policy.sustainedCellID, "s4-p1536-o512")
        XCTAssertEqual(policy.temperature, 0)
        XCTAssertEqual(policy.mtpSHA256, policy.targetSHA256, "the embedded MTP artifact is the target")
        XCTAssertNoThrow(try policy.validateFamily(.glm5Next))
        XCTAssertNoThrow(try policy.validateFamily(.qwen35))
    }

    func testResumeCountsARecordOnlyForItsPolicyCellShapeAndPhase() throws {
        let policy = try NativeMTPBenchPolicy.load(from: Self.glmPolicyURL)
        func check(
            cell: String, slots: Int = 2, prompt: Int = 1536, output: Int = 512,
            block: Int, sustained: Bool = false, warmup: Bool = false
        ) throws {
            try NativeMTPExistingEvidence.validateResumedRecord(
                ["slots": slots, "prompt_tokens": prompt, "max_tokens": output],
                cellID: cell, block: block, sustained: sustained, warmup: warmup, policy: policy, line: 2
            )
        }
        XCTAssertNoThrow(try check(cell: "s2-p1536-o512", block: 9))
        XCTAssertNoThrow(try check(cell: "s2-p1536-o512", block: -1, warmup: true))
        XCTAssertNoThrow(try check(cell: "s4-p1536-o512", slots: 4, block: 12, sustained: true))
        // A record whose fields name another stratum than its cell id.
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", slots: 4, block: 0))
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", prompt: 4096, block: 0))
        // A cell the policy does not have.
        XCTAssertThrowsError(try check(cell: "s8-p1536-o512", slots: 8, block: 0))
        // Blocks outside their phase.
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", block: 10))
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", block: -1))
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", block: -2, warmup: true))
        XCTAssertThrowsError(try check(cell: "s2-p1536-o512", block: 0, sustained: true))
    }

    func testGreedyOnlyFamilyRefusesASampledPolicyBeforeLoading() throws {
        var object = try glmPolicyObject()
        object["temperature"] = 0.7
        let policy = try load(object)
        XCTAssertThrowsError(try policy.validateFamily(.glm5Next)) { error in
            XCTAssertTrue("\(error)".contains("greedy rows only"), "\(error)")
        }
        XCTAssertNoThrow(try policy.validateFamily(.qwen35))
    }

    func testSignedOneRowBoundRefusesAWiderPolicyBeforeLoading() throws {
        var object = try glmPolicyObject()
        object["max_native_active_rows"] = 2
        object["slots"] = [1, 2]
        object["gated_cells"] = ["s3-p1536-o512", "s4-p1536-o512"]
        let policy = try load(object)
        XCTAssertThrowsError(try policy.validateFamily(.glm5Next)) { error in
            XCTAssertTrue("\(error)".contains("max_native_active_rows must be at most 1"), "\(error)")
        }
    }

    func testValidateOnlyIsAnOptInFlag() throws {
        let base = ["--root", "/fixture", "--policy", "/p.json", "--out", "/o.jsonl", "--provider-commit", String(repeating: "a", count: 40)]
        XCTAssertFalse(try NativeMTPBenchCommand.parse(base).validateOnly)
        XCTAssertTrue(try NativeMTPBenchCommand.parse(base + ["--validate-only"]).validateOnly)
    }

    private func glmPolicyObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.glmPolicyURL)) as? [String: Any])
    }

    private func load(_ object: [String: Any]) throws -> NativeMTPBenchPolicy {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPBenchGLMTests-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NativeMTPBenchPolicy.load(from: url)
    }

    private func fixtureRoot(config: Data?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPBenchGLMTests-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let config {
            try config.write(to: target.appendingPathComponent("config.json"))
        }
        return root
    }
}
#endif
