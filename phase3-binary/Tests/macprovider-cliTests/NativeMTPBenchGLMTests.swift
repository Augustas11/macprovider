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

    func testExploratorySamplingAndToolsKeepFormalPoliciesClosed() throws {
        for (key, value) in [("top_p", 0.95 as Any), ("request_shape", "tools" as Any)] {
            var formal = try glmPolicyObject()
            formal[key] = value
            XCTAssertThrowsError(try load(formal))
        }
        var object = try glmPolicyObject()
        object["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
        object["temperature"] = 1.0
        object["top_p"] = 0.95
        object["request_shape"] = "tools"
        object["slots"] = [1, 2, 4]
        object["prompt_tokens"] = [512]
        object["max_tokens"] = [128]
        object["blocks"] = 2
        object["sustained_seconds"] = 0
        object["gated_cells"] = []
        object["sustained_cell_id"] = "s4-p512-o128"
        let policy = try load(object)
        XCTAssertNoThrow(try policy.validateFamily(.glm5Next))
        XCTAssertEqual(policy.topP, 0.95)
        XCTAssertEqual(policy.requestShape, "tools")
        XCTAssertTrue(policy.observesFeatureGate(.sampling))
        XCTAssertTrue(policy.observesFeatureGate(.tools))
        XCTAssertTrue(policy.observesFeatureGate(.reasoningOrTemplate))
        XCTAssertTrue(policy.observesFeatureGate(.unknownRequestField))
        for reason in [nil, .capabilityMismatch, .tupleNotAdmitted] as [NativeMTPSelectorReason?] {
            XCTAssertFalse(policy.observesFeatureGate(reason))
        }
        let formal = try load(glmPolicyObject())
        XCTAssertFalse(formal.observesFeatureGate(.sampling))
        XCTAssertFalse(formal.observesFeatureGate(.tools))
        object["schema"] = "macprovider.native-mtp-r015-policy.v1"
        object.removeValue(forKey: "top_p")
        object.removeValue(forKey: "request_shape")
        XCTAssertThrowsError(try load(object), "formal matrix and minimums remain mandatory")
    }

    func testExploratoryRequestOptionsRejectMalformedValues() throws {
        for value in [0, -0.1, 1.1, true, "0.95"] as [Any] {
            var object = try glmPolicyObject()
            object["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
            object["top_p"] = value
            XCTAssertThrowsError(try load(object))
        }
        for value in ["unknown", true, NSNull()] as [Any] {
            var object = try glmPolicyObject()
            object["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
            object["request_shape"] = value
            XCTAssertThrowsError(try load(object))
        }
    }

    func testRequestsPreservePairIdentitySamplingAndToolReasoningHistory() throws {
        let requestID = "s2-p512-o128-b0-r1"
        let plain = try NativeMTPBenchPrompts.makeRequest(
            modelID: "glm", requestID: requestID, prompt: "Measure tokens.",
            maxTokens: 128, temperature: 1, topP: 0.95
        )
        XCTAssertEqual(plain.requestID, requestID)
        XCTAssertEqual(plain.topP, 0.95)
        XCTAssertEqual(plain.temperature, 1)
        XCTAssertEqual(plain.messages.count, 1)
        XCTAssertFalse(plain.topLevelKeys.contains("tools"))
        for _ in 0..<2 {
            let tools = try NativeMTPBenchPrompts.makeRequest(
                modelID: "glm", requestID: requestID, prompt: "Measure tokens.",
                maxTokens: 128, temperature: 1, topP: 0.95, requestShape: "tools"
            )
            XCTAssertEqual(tools.requestID, plain.requestID)
            XCTAssertEqual(tools.maxTokens, 128)
            XCTAssertEqual(tools.temperature, plain.temperature)
            XCTAssertEqual(tools.topP, plain.topP)
            XCTAssertTrue(tools.topLevelKeys.contains("tools"))
            XCTAssertEqual(tools.reasoningEffort, "high")
            XCTAssertEqual(tools.messages.map(\.role.rawValue), ["user", "assistant", "tool", "user"])
            XCTAssertEqual(tools.messages[1].reasoningContent, "I will look up the measurement value.")
            XCTAssertEqual(tools.messages[1].toolCalls?.first?.id, "measurement_call")
            XCTAssertEqual(tools.messages[2].toolCallID, "measurement_call")
            XCTAssertEqual(tools.messages[3].content, plain.messages[0].content)
        }
    }

    func testCommittedTokenDigestIsFixedWidthOrderedAndCountsAllCommits() {
        func event(_ ordinal: Int, _ tokenID: Int?) -> NativeMTPLabCommittedTokenTimingObserver.Event {
            .init(requestID: "row", monotonicNanoseconds: UInt64(110 + ordinal * 10),
                  ordinal: ordinal, outputCount: ordinal + 1, tokenID: tokenID)
        }
        // Postprocessed completion length need not equal commits (reasoning,
        // tool controls and stop truncation are still part of token parity).
        let evidence = NativeMTPBenchTokenEvidence(
            events: [event(0, 7), event(1, 19)], startedNanoseconds: 100, generatedTokens: 1
        )
        XCTAssertTrue(evidence.complete)
        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence.sha256, "1115923c665bd7703fa56c50a39e768829e2e8d0f3024645ea8b89b1083e5db4")
        XCTAssertEqual(evidence.ttftSeconds, 0.00000001)
        XCTAssertEqual(evidence.interTokenGaps, [0.00000001])
        let reversed = NativeMTPBenchTokenEvidence(
            events: [event(0, 19), event(1, 7)], startedNanoseconds: 100, generatedTokens: 1
        )
        XCTAssertNotEqual(reversed.sha256, evidence.sha256)
        for incomplete in [[], [event(0, nil)], [event(1, 7)], [event(0, 7), event(0, 19)]] {
            XCTAssertFalse(NativeMTPBenchTokenEvidence(
                events: incomplete, startedNanoseconds: 100, generatedTokens: 1
            ).complete)
        }
        XCTAssertFalse(NativeMTPBenchTokenEvidence(
            events: [event(0, 7)], startedNanoseconds: 111, generatedTokens: 1
        ).complete)
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
