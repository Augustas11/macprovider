import ArgumentParser
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPQualificationTests: XCTestCase {
    func testQualificationRegistersOnlyIsolatedMeasurementCommands() {
        let commands = NativeMTPQualificationCommand.configuration.subcommands
        XCTAssertEqual(commands.map { $0.configuration.commandName! }, ["acceptance", "bench", "replay"])
        XCTAssertFalse(commands.contains { $0 == ServeCommand.self })
        XCTAssertThrowsError(try NativeMTPQualificationCommand.parseAsRoot(["serve", "--no-join"]))
        XCTAssertThrowsError(try NativeMTPQualificationCommand.parseAsRoot(["native-mtp-journey-e2e"]))
    }

    func testMeasurementIdentityComesOnlyFromOpenedTaskScope() async throws {
        XCTAssertNil(NativeMTPQualificationScope.bind(["record_type": "run"])["measurement_identity"])
        let identity = NativeMTPMeasurementIdentity(binarySHA256: String(repeating: "1", count: 64), binaryCDHash: String(repeating: "2", count: 40))
        await NativeMTPQualificationScope.$identity.withValue(identity) {
            for type in ["header", "run", "sustained"] {
                let result = NativeMTPQualificationScope.bind(["record_type": type, "measurement_identity": ["binary_sha256": "caller"]])
                XCTAssertEqual(result["measurement_identity"] as? [String: String], identity.document)
            }
            let child = Task { NativeMTPQualificationScope.identity }
            let inherited = await child.value
            XCTAssertEqual(inherited, identity)
        }
        XCTAssertNil(NativeMTPQualificationScope.identity)
    }

    func testSignedAcceptanceHasNoJourneyOrServeBypassArguments() {
        for arguments in [["--self-test-only"], ["--journey-step", "05"], ["--no-join"], ["--prepare-acceptance-corpus", "out.json"]] {
            XCTAssertThrowsError(try NativeMTPSignedAcceptanceCommand.parse(arguments))
        }
    }
    private var policyURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/research/spec048-r015/glm53-flash-r015-v2/policy.json")
    }

    func testSignedMatrixAndSustainedResumeRejectOtherExecutable() async throws {
        let policy = try NativeMTPBenchPolicy.load(from: policyURL)
        let identity = NativeMTPMeasurementIdentity(binarySHA256: String(repeating: "1", count: 64), binaryCDHash: String(repeating: "2", count: 40))
        try NativeMTPQualificationScope.$identity.withValue(identity) {
            for sustained in [false, true] {
                var record: [String: Any] = ["slots": 4, "prompt_tokens": 1536, "max_tokens": 512]
                func check() throws {
                    try NativeMTPExistingEvidence.validateResumedRecord(record, cellID: "s4-p1536-o512", block: 0,
                        sustained: sustained, warmup: false, policy: policy, line: 2)
                }
                XCTAssertThrowsError(try check())
                record["measurement_identity"] = identity.document
                XCTAssertNoThrow(try check())
                record["measurement_identity"] = ["binary_sha256": String(repeating: "3", count: 64), "binary_cdhash": identity.binaryCDHash]
                XCTAssertThrowsError(try check())
            }
        }
    }

    func testSignedBenchRejectsExploratoryBeforeOpeningSignatureScope() async throws {
        var policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as? [String: Any])
        policy["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: policy).write(to: url)
        let command = try NativeMTPSignedBenchCommand.parse(["--root", "/unused", "--policy", url.path,
            "--out", "/unused", "--provider-commit", String(repeating: "a", count: 40)])
        do { try await command.run(); XCTFail("exploratory qualification accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("forbids exploratory"), String(describing: error)) }
        XCTAssertNil(NativeMTPQualificationScope.identity)
    }

    func testAcceptanceCheckpointCannotImportUnboundOrOtherBinaryRows() async throws {
        let strata = ["short", "1.5k", "4k", "8k", "near_boundary"]
        let cases: [[String: Any]] = (0..<200).map { i in
            ["id": "case-\(i)", "stratum": strata[i % 5], "expected_native": i % 5 != 3,
             "request": ["model": "zai-org/glm-5.3-flash", "messages": [["role": "user", "content": "Explain a harbor."]],
                         "max_tokens": 64, "temperature": 1.0, "top_p": 0.95, "stream": false]]
        }
        let corpus = try NativeMTPAcceptanceCorpus.load(data: JSONSerialization.data(withJSONObject: [
            "schema": NativeMTPAcceptanceCorpus.schema, "model_id": "zai-org/glm-5.3-flash", "max_prompt_tokens": 4096,
            "qualified_slots": 4, "max_native_active_rows": 1, "proposal_depth": 1, "minimum_compared_positions": 6400, "cases": cases]))
        let sha = String(repeating: "a", count: 64)
        let policy = NativeMTPAcceptancePolicy(modelID: corpus.modelID, targetSHA256: sha, mtpSHA256: sha,
            tokenizerSHA256: sha, hwModel: "Mac15,14", chip: "Apple M3 Ultra", ramGB: 256,
            osBuild: "test", xcodeBuildVersion: "test", swiftVersion: "test", providerCommit: String(repeating: "b", count: 40),
            mlxForkRevision: NativeMTPHardwareE2ERunner.upstreamRevision, quantization: "4bit", cacheMode: "paged_kv_mixed",
            corpusSHA256: corpus.digestSHA256, digestSHA256: sha)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = NativeMTPMeasurementIdentity(binarySHA256: sha, binaryCDHash: String(repeating: "c", count: 40))
        try NativeMTPQualificationScope.$identity.withValue(identity) {
            let checkpoint = try SignedAcceptanceCheckpoint(path: url.path, policy: policy, corpus: corpus)
            try checkpoint.persist([])
            XCTAssertNoThrow(try SignedAcceptanceCheckpoint(path: url.path, policy: policy, corpus: corpus))
            for field in ["binary_sha256", "binary_cdhash"] {
                var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                let saved = document[field]
                document[field] = "wrong"
                try JSONSerialization.data(withJSONObject: document).write(to: url)
                XCTAssertThrowsError(try SignedAcceptanceCheckpoint(path: url.path, policy: policy, corpus: corpus))
                document[field] = saved
                try JSONSerialization.data(withJSONObject: document).write(to: url)
            }
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            legacy["binary_sha256"] = nil; legacy["binary_cdhash"] = nil
            try JSONSerialization.data(withJSONObject: legacy).write(to: url)
            XCTAssertThrowsError(try SignedAcceptanceCheckpoint(path: url.path, policy: policy, corpus: corpus))
        }
    }

}
