import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPLabCBInputsTests: XCTestCase {
    func testProductionBuildAndUnqualifiedScopeCannotLoadLabInputs() throws {
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireScope(labHarnessBuild: false, fixtureHooksPermitted: true))
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireScope(labHarnessBuild: true, fixtureHooksPermitted: false))
        XCTAssertNoThrow(try NativeMTPLabCBInputs.requireScope(labHarnessBuild: true, fixtureHooksPermitted: true))
    }

    func testMissingInputsFailsClosedForDeepSeekOnly() throws {
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireInputs(nil, deepseek: true))
        XCTAssertNoThrow(try NativeMTPLabCBInputs.requireInputs(nil, deepseek: false))
    }

    func testRealSignedCatalogAndPolicyAdmitOnlyExactRuntimeTuple() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.verify()
        XCTAssertEqual(result.status, .liveVerified)
        XCTAssertNoThrow(try NativeMTPLabCBInputs.requireAdmission(result, tuple: fixture.tuple, slots: 4))
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireAdmission(result, tuple: fixture.tuple, slots: 5))
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireAdmission(result,
            tuple: requestedTuple(template: String(repeating: "9", count: 64)), slots: 1))
        XCTAssertThrowsError(try NativeMTPLabCBInputs.requireAdmission(result,
            tuple: requestedTuple(tokenizer: String(repeating: "9", count: 64)), slots: 1))
    }

    func testTamperedCatalogAndPolicyFailCanonicalSignatureVerification() async throws {
        let fixture = try makeFixture()
        for tamperCatalog in [true, false] {
            do {
                _ = try await fixture.verify(tamperCatalog: tamperCatalog, tamperPolicy: !tamperCatalog)
                XCTFail("Tampered signed inputs must fail closed")
            } catch { }
        }
    }

    func testChangedRetainedEvidenceFailsBeforeSigningOrRuntimeLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("changed qualification evidence".utf8).write(to: directory.appendingPathComponent("throughput-r4.json"))
        let inputs = NativeMTPLabCBInputs(directory: directory, providerCommit: String(repeating: "a", count: 40))
        do {
            _ = try await inputs.load(tuple: requestedTuple(), slots: 1)
            XCTFail("Changed retained evidence must fail closed")
        } catch { }
    }

    private struct Fixture {
        let catalog: Data
        let policy: Data
        let catalogSignature: Data
        let policySignature: Data
        let publicKey: String
        let tuple: ContinuousBatchingRequestedTuple

        func verify(tamperCatalog: Bool = false, tamperPolicy: Bool = false) async throws -> ContinuousBatchingPolicyLoadResult {
            try await NativeMTPLabCBInputs.verify(
                catalog: tamperCatalog ? catalog + Data(" ".utf8) : catalog,
                catalogSignature: catalogSignature,
                policy: tamperPolicy ? policy + Data(" ".utf8) : policy,
                policySignature: policySignature,
                keyID: "native-mtp-test", publicKey: publicKey)
        }
    }

    private func requestedTuple(tokenizer: String = String(repeating: "c", count: 64),
                                template: String = String(repeating: "d", count: 64)) -> ContinuousBatchingRequestedTuple {
        ContinuousBatchingRequestedTuple(modelID: "deepseek/deepseek-v4-flash",
            modelSHA256: "58ee40d4c0bc436695d1d8d6a6cdfdb0326ec37f25e13ec98ea1d5c0878e732c", tokenizerSHA256: tokenizer,
            chatTemplateSHA256: template, cacheClass: "mixed", kvDType: .fp16, requiresMoE: true,
            hardwareClass: "apple-silicon:Apple M3 Ultra:ram-256gb",
            metallibSHA256: String(repeating: "e", count: 64),
            kernelIdentifier: "deepseek-v4-row-pool-decode-v1", parityLabel: "parity", poolEpoch: 1)
    }

    private func makeFixture() throws -> Fixture {
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "native-mtp-test"
        let catalog = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let value = try AutotuneStaticInputs.decodeCandidateCatalog(catalog)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        let generated = try XCTUnwrap(object["generated_at"] as? String)
        let expires = "9999-12-31T23:59:59Z"
        let tuple = requestedTuple()
        var entry: [String: Any] = [
            "model_key": tuple.modelID, "model_id": tuple.modelID, "model_sha256": tuple.modelSHA256,
            "tokenizer_sha256": try XCTUnwrap(tuple.tokenizerSHA256),
            "chat_template_sha256": try XCTUnwrap(tuple.chatTemplateSHA256),
            "cache_class": tuple.cacheClass, "kv_dtype": "fp16", "requires_moe": true,
            "hardware_class": tuple.hardwareClass, "metallib_sha256": tuple.metallibSHA256,
            "kernel_identifier": tuple.kernelIdentifier, "rollout": "on", "cached_turns_accepted": false,
            "max_served_slots": 4,
            "provenance": ["source": "operator_review", "status": "qualified", "evidence_id": "unit-test",
                "package_manifest_sha256": String(repeating: "5", count: 64),
                "studio_campaign_sha256": String(repeating: "6", count: 64),
                "provider_cli_version": "test", "live_executable_cdhash": String(repeating: "7", count: 40)],
        ]
        entry["tuple_sha256"] = try ContinuousBatchingSignedPolicy.tupleSHA256(
            releaseID: value.version, policyVersion: value.policyVersion, generatedAt: generated,
            expiresAt: expires, candidateCatalogSHA256: NativeMTPLabCBInputs.sha(catalog),
            signerKeyID: keyID, entry: entry)
        let policy = try NativeMTPLabCBInputs.json([
            "schema_version": ContinuousBatchingSignedPolicy.schemaVersion, "release_id": value.version,
            "policy_version": value.policyVersion, "generated_at": generated, "expires_at": expires,
            "candidate_catalog_sha256": NativeMTPLabCBInputs.sha(catalog), "signer_key_id": keyID, "entries": [entry],
        ])
        func signature(_ data: Data) throws -> Data {
            try NativeMTPLabCBInputs.json(["key_id": keyID, "alg": "ed25519",
                "signature": signer.signature(for: data).base64EncodedString()])
        }
        return Fixture(catalog: catalog, policy: policy, catalogSignature: try signature(catalog),
            policySignature: try signature(policy), publicKey: signer.publicKey.rawRepresentation.base64EncodedString(),
            tuple: tuple)
    }
}
