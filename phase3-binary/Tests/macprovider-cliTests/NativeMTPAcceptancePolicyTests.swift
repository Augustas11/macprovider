#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPAcceptancePolicyTests: XCTestCase {
    private let model = "zai-org/glm-5.3-flash"
    private let artifact = String(repeating: "a", count: 64)
    private let commit = String(repeating: "b", count: 40)

    private func corpusData(modelID: String? = nil) throws -> Data {
        let modelID = modelID ?? model
        let strata = ["short", "1.5k", "4k", "8k", "near_boundary"]
        let cases: [[String: Any]] = (0..<200).map { index in
            ["id": "case-\(index)", "stratum": strata[index % 5], "expected_native": index % 5 != 3,
             "request": ["model": modelID, "messages": [["role": "user", "content": "Describe a quiet harbor."]],
                         "max_tokens": 64, "temperature": 1.0, "top_p": 0.95, "stream": false]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema": NativeMTPAcceptanceCorpus.schema, "model_id": modelID,
            "max_prompt_tokens": 4096, "qualified_slots": 4, "max_native_active_rows": 1,
            "proposal_depth": 1, "minimum_compared_positions": 6400, "cases": cases,
        ], options: [.sortedKeys])
    }

    private func object(corpus: NativeMTPAcceptanceCorpus) -> [String: Any] {
        ["schema": NativeMTPAcceptancePolicy.schema, "model_id": model,
         "target_sha256": artifact, "mtp_sha256": artifact, "tokenizer_sha256": artifact,
         "hw_model": "Mac15,14", "chip": "Apple M3 Ultra", "ram_gb": 256,
         "os_build": "26A434", "xcode_build_version": "17A100", "swift_version": "Apple Swift 6.3.3",
         "provider_commit": commit, "mlx_fork_revision": NativeMTPHardwareE2ERunner.upstreamRevision,
         "quantization": "4bit", "cache_mode": "paged_kv_mixed", "corpus_sha256": corpus.digestSHA256]
    }

    private func load(_ object: [String: Any]) throws -> NativeMTPAcceptancePolicy {
        try NativeMTPAcceptancePolicy.load(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func environment(
        hwModel: String = "Mac15,14", chip: String = "Apple M3 Ultra", ram: Int = 256,
        os: String = "26A434", xcode: String = "17A100", swift: String = "Apple Swift 6.3.3",
        source: String? = nil
    ) -> NativeMTPBenchEnvironment {
        .init(hwModel: hwModel, chip: chip, ramGB: ram, osVersion: "unused display version", osBuild: os,
              xcodeBuildVersion: xcode, swiftVersion: swift, providerCommit: source ?? commit)
    }

    private func validate(_ policy: NativeMTPAcceptancePolicy, corpus: NativeMTPAcceptanceCorpus,
                          environment: NativeMTPBenchEnvironment? = nil) throws {
        try policy.validate(corpus: corpus, environment: environment ?? self.environment(),
                            targetSHA256: artifact, mtpSHA256: artifact, tokenizerSHA256: artifact)
    }

    func testMatchingPolicyAndOriginalByteDigest() throws {
        let corpus = try NativeMTPAcceptanceCorpus.load(data: corpusData())
        let data = try JSONSerialization.data(withJSONObject: object(corpus: corpus), options: [.sortedKeys])
        let policy = try NativeMTPAcceptancePolicy.load(data: data)
        try validate(policy, corpus: corpus)
        XCTAssertEqual(policy.modelID, model)
        XCTAssertEqual(policy.providerCommit, commit)
        XCTAssertEqual(policy.policyJSON.count, 16)
        XCTAssertEqual(policy.policyJSON["corpus_sha256"] as? String, corpus.digestSHA256)
        XCTAssertNotEqual(policy.digestSHA256, try NativeMTPAcceptancePolicy.load(data: data + Data("\n".utf8)).digestSHA256)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try NativeMTPAcceptancePolicy.load(from: url).digestSHA256, policy.digestSHA256)
    }

    func testEveryEnvironmentIdentityMismatchIsRejected() throws {
        let corpus = try NativeMTPAcceptanceCorpus.load(data: corpusData())
        let policy = try load(object(corpus: corpus))
        let changes: [(String, NativeMTPBenchEnvironment)] = [
            ("hw_model", environment(hwModel: "Mac16,9")), ("chip", environment(chip: "other")),
            ("ram_gb", environment(ram: 128)), ("os_build", environment(os: "other")),
            ("xcode_build_version", environment(xcode: "other")), ("swift_version", environment(swift: "other")),
            ("provider_commit", environment(source: String(repeating: "c", count: 40))),
        ]
        for (field, observed) in changes {
            XCTAssertThrowsError(try validate(policy, corpus: corpus, environment: observed), field) {
                XCTAssertTrue(String(describing: $0).contains("\(field) mismatch"))
            }
        }
        var changed = object(corpus: corpus)
        changed["mlx_fork_revision"] = String(repeating: "d", count: 40)
        XCTAssertThrowsError(try validate(load(changed), corpus: corpus)) {
            XCTAssertTrue(String(describing: $0).contains("mlx_fork_revision mismatch"))
        }
    }

    func testEveryArtifactAndCorpusIdentityMismatchIsRejected() throws {
        let corpus = try NativeMTPAcceptanceCorpus.load(data: corpusData())
        for field in ["model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "corpus_sha256"] {
            var changed = object(corpus: corpus)
            changed[field] = field == "model_id" ? "other/model" : String(repeating: "f", count: 64)
            XCTAssertThrowsError(try validate(load(changed), corpus: corpus), field) {
                XCTAssertTrue(String(describing: $0).contains("\(field) mismatch"))
            }
        }
        let policy = try load(object(corpus: corpus))
        let differentBytes = try NativeMTPAcceptanceCorpus.load(data: corpusData() + Data("\n".utf8))
        XCTAssertThrowsError(try validate(policy, corpus: differentBytes))
        let otherModel = try NativeMTPAcceptanceCorpus.load(data: corpusData(modelID: "other/model"))
        var boundToOtherBytes = object(corpus: otherModel)
        boundToOtherBytes["model_id"] = model
        XCTAssertThrowsError(try validate(load(boundToOtherBytes), corpus: otherModel)) {
            XCTAssertTrue(String(describing: $0).contains("model_id mismatch"))
        }
    }

    func testClosedKeysDuplicateKeysAndStrictTypes() throws {
        let corpus = try NativeMTPAcceptanceCorpus.load(data: corpusData())
        let valid = object(corpus: corpus)
        for field in valid.keys {
            var missing = valid
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try load(missing), field)
            var wrongType = valid
            if field == "ram_gb" { wrongType[field] = "256" } else { wrongType[field] = 42 }
            XCTAssertThrowsError(try load(wrongType), field)
        }
        var unknown = valid
        unknown["throughput_lower_bound_min"] = 0
        XCTAssertThrowsError(try load(unknown))
        for value: Any in [true, 0, -1, 256.5, 16_385] {
            var changed = valid
            changed["ram_gb"] = value
            XCTAssertThrowsError(try load(changed))
        }
        let data = try JSONSerialization.data(withJSONObject: valid, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        let duplicate = "{\"corpus_sha256\":\"" + corpus.digestSHA256 + "\"," + text.dropFirst()
        XCTAssertThrowsError(try NativeMTPAcceptancePolicy.load(data: Data(duplicate.utf8)))
    }

    func testFrozenConstantsAndHexDomains() throws {
        let corpus = try NativeMTPAcceptanceCorpus.load(data: corpusData())
        let valid = object(corpus: corpus)
        for (field, value) in [("schema", "other"), ("hw_model", "Mac16,9"),
                               ("quantization", "8bit"), ("cache_mode", "ordinary")] {
            var changed = valid
            changed[field] = value
            XCTAssertThrowsError(try load(changed), field)
        }
        for field in ["target_sha256", "mtp_sha256", "tokenizer_sha256", "corpus_sha256", "provider_commit", "mlx_fork_revision"] {
            let count = field == "provider_commit" || field == "mlx_fork_revision" ? 40 : 64
            for value in [String(repeating: "a", count: count - 1), String(repeating: "A", count: count),
                          String(repeating: "g", count: count)] {
                var changed = valid
                changed[field] = value
                XCTAssertThrowsError(try load(changed), field)
            }
        }
        for field in ["model_id", "chip", "os_build", "xcode_build_version", "swift_version"] {
            var changed = valid
            changed[field] = " "
            XCTAssertThrowsError(try load(changed), field)
        }
    }
}
#endif
