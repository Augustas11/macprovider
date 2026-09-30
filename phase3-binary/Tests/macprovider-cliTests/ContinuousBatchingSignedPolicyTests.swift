import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ContinuousBatchingSignedPolicyTests: XCTestCase {
    func testValidSignedPolicyProducesExactCoverage() throws {
        let fixture = try makeFixture()

        let selection = try ContinuousBatchingSignedPolicy.verify(
            policyData: fixture.policyData,
            signatureData: fixture.signatureData,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )

        XCTAssertEqual(selection.releaseID, "published-2026-09-30-cb-test")
        XCTAssertEqual(selection.policyVersion, "autotune-policy-v1")
        XCTAssertEqual(selection.signerKeyID, fixture.keyID)
        XCTAssertEqual(selection.entries.count, 1)
        XCTAssertEqual(selection.entries.first?.rollout, .on)
        XCTAssertEqual(selection.entries.first?.provenance.status, "qualified")
        XCTAssertTrue(selection.acceptanceCoverage.covers(fixture.requestedTuple))
        XCTAssertTrue(selection.acceptanceCoverage.coversCachedTurns(fixture.requestedTuple))
    }

    func testValidMixedCachePolicyProducesExactCoverage() throws {
        let fixture = try makeFixture(cacheClass: "mixed")

        let selection = try ContinuousBatchingSignedPolicy.verify(
            policyData: fixture.policyData,
            signatureData: fixture.signatureData,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )

        XCTAssertEqual(selection.entries.first?.tuple.cacheClass, "mixed")
        XCTAssertTrue(selection.acceptanceCoverage.covers(fixture.requestedTuple))
    }

    func testRolloutOffIsVerifiedButDoesNotAuthorizeCoverage() throws {
        let fixture = try makeFixture(mutate: { entry in
            entry["rollout"] = "off"
        })

        let selection = try ContinuousBatchingSignedPolicy.verify(
            policyData: fixture.policyData,
            signatureData: fixture.signatureData,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )

        XCTAssertTrue(selection.entries.isEmpty)
        XCTAssertFalse(selection.acceptanceCoverage.covers(fixture.requestedTuple))
    }

    func testRuntimeProvenanceRequiresExactProviderVersionAndCDHash() throws {
        let fixture = try makeFixture()
        let selection = try ContinuousBatchingSignedPolicy.verify(
            policyData: fixture.policyData,
            signatureData: fixture.signatureData,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )
        let entry = try XCTUnwrap(selection.entries.first)

        XCTAssertTrue(ContinuousBatchingSignedPolicy.matchesRuntimeProvenance(
            entry,
            providerCLIVersion: "1.8.208-candidate",
            liveExecutableCDHash: String(repeating: "7", count: 40)
        ))
        XCTAssertFalse(ContinuousBatchingSignedPolicy.matchesRuntimeProvenance(
            entry,
            providerCLIVersion: "1.8.209",
            liveExecutableCDHash: String(repeating: "7", count: 40)
        ))
        XCTAssertFalse(ContinuousBatchingSignedPolicy.matchesRuntimeProvenance(
            entry,
            providerCLIVersion: "1.8.208-candidate",
            liveExecutableCDHash: String(repeating: "8", count: 40)
        ))
        XCTAssertFalse(ContinuousBatchingSignedPolicy.matchesRuntimeProvenance(
            entry,
            providerCLIVersion: "1.8.208-candidate",
            liveExecutableCDHash: nil
        ))
    }

    func testRejectsTamperedSignature() throws {
        let fixture = try makeFixture()
        var tampered = fixture.policyData
        tampered.append(0x20)

        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: tampered,
            signatureData: fixture.signatureData,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .signatureInvalid("verification_failed"))
        }
    }

    func testRejectsUnsignedOrUnexpectedKey() throws {
        let fixture = try makeFixture()
        let otherSigner = Curve25519.Signing.PrivateKey()
        let otherKeyID = "streamvc-autotune-static-other"
        let otherSignature = signatureData(payload: fixture.policyData, signer: otherSigner, keyID: otherKeyID)

        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: fixture.policyData,
            signatureData: otherSignature,
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .signatureInvalid("unexpected_key_id"))
        }
    }

    func testRejectsDuplicateKeysBeforePolicyCanAuthorize() throws {
        let fixture = try makeFixture()
        let duplicate = Data("""
        {"schema_version":"\(ContinuousBatchingSignedPolicy.schemaVersion)","schema_version":"\(ContinuousBatchingSignedPolicy.schemaVersion)"}
        """.utf8)

        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: duplicate,
            signatureData: signatureData(payload: duplicate, signer: fixture.signer, keyID: fixture.keyID),
            catalog: fixture.catalog,
            trustedKeyring: fixture.trustedKeyring,
            now: fixture.now
        ))
    }

    func testRejectsExpiredFutureAndCatalogMismatchedPolicy() throws {
        let expired = try makeFixture(
            generatedAt: "2026-09-28T00:00:00Z",
            expiresAt: "2026-09-29T00:00:00Z"
        )
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: expired.policyData,
            signatureData: expired.signatureData,
            catalog: expired.catalog,
            trustedKeyring: expired.trustedKeyring,
            now: expired.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .expired)
        }

        let future = try makeFixture(generatedAt: "2026-10-01T00:00:00Z")
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: future.policyData,
            signatureData: future.signatureData,
            catalog: future.catalog,
            trustedKeyring: future.trustedKeyring,
            now: future.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .futureDated)
        }

        let mismatchedCatalog = try makeFixture()
        var wrongCatalog = mismatchedCatalog.catalog
        wrongCatalog.selectedBytes = Data(#"{"not":"the selected catalog"}"#.utf8)
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: mismatchedCatalog.policyData,
            signatureData: mismatchedCatalog.signatureData,
            catalog: wrongCatalog,
            trustedKeyring: mismatchedCatalog.trustedKeyring,
            now: mismatchedCatalog.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .catalogMismatch)
        }

        let mismatchedGeneratedAt = try makeFixture(
            generatedAt: "2026-09-29T00:00:00Z",
            catalogGeneratedAt: "2026-09-30T00:00:00Z"
        )
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: mismatchedGeneratedAt.policyData,
            signatureData: mismatchedGeneratedAt.signatureData,
            catalog: mismatchedGeneratedAt.catalog,
            trustedKeyring: mismatchedGeneratedAt.trustedKeyring,
            now: mismatchedGeneratedAt.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .rowMismatch("$.generated_at"))
        }
    }

    func testEveryAcceptanceBoundFieldInvalidatesLocalCoverage() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("model_id", { $0["model_id"] = "qwen/other" }),
            ("model_sha256", { $0["model_sha256"] = String(repeating: "1", count: 64) }),
            ("tokenizer_sha256", { $0["tokenizer_sha256"] = String(repeating: "2", count: 64) }),
            ("chat_template_sha256", { $0["chat_template_sha256"] = String(repeating: "3", count: 64) }),
            ("cache_class", { $0["cache_class"] = "OtherCache" }),
            ("kv_dtype", { $0["kv_dtype"] = "bf16" }),
            ("requires_moe", { $0["requires_moe"] = true }),
            ("hardware_class", { $0["hardware_class"] = "apple-silicon:m4-max:ram-128gb" }),
            ("metallib_sha256", { $0["metallib_sha256"] = String(repeating: "4", count: 64) }),
            ("kernel_identifier", { $0["kernel_identifier"] = "macprovider_other_kernel" }),
        ]

        for (field, mutate) in cases {
            let fixture = try makeFixture(mutate: { entry in
                mutate(&entry)
            })
            do {
                let selection = try ContinuousBatchingSignedPolicy.verify(
                    policyData: fixture.policyData,
                    signatureData: fixture.signatureData,
                    catalog: fixture.catalog,
                    trustedKeyring: fixture.trustedKeyring,
                    now: fixture.now
                )
                XCTAssertFalse(selection.acceptanceCoverage.covers(fixture.requestedTuple), field)
            } catch let error as ContinuousBatchingSignedPolicyError {
                switch error {
                case .rowMismatch, .unsupported:
                    break
                default:
                    XCTFail("\(field) rejected with unexpected error \(error)")
                }
            }
        }
    }

    func testMalformedSchemaAndTupleDigestAreRejected() throws {
        let unknown = try makeFixture(mutate: { entry in
            entry["unexpected"] = "nope"
        })
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: unknown.policyData,
            signatureData: unknown.signatureData,
            catalog: unknown.catalog,
            trustedKeyring: unknown.trustedKeyring,
            now: unknown.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .unknownField("$.entries[0].unexpected"))
        }

        let staleTupleDigest = try makeFixture(recomputeTuple: false, mutate: { entry in
            entry["kernel_identifier"] = "macprovider_other_kernel"
        })
        XCTAssertThrowsError(try ContinuousBatchingSignedPolicy.verify(
            policyData: staleTupleDigest.policyData,
            signatureData: staleTupleDigest.signatureData,
            catalog: staleTupleDigest.catalog,
            trustedKeyring: staleTupleDigest.trustedKeyring,
            now: staleTupleDigest.now
        )) { error in
            XCTAssertEqual(error as? ContinuousBatchingSignedPolicyError, .invalidValue("$.entries[0].tuple_sha256"))
        }
    }

    func testLoaderReturnsLiveVerifiedOrReasonCodedEmptyFallback() async throws {
        let fixture = try makeFixture()
        let baseURL = URL(string: "https://example.invalid")!
        let liveInputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case "/v1/continuous-batching-policy":
                    return fixture.policyData
                case "/v1/continuous-batching-policy.sig":
                    return fixture.signatureData
                default:
                    throw URLError(.fileDoesNotExist)
                }
            },
            trustedPublicKeys: fixture.trustedKeyring.publicKeysByKeyID,
            now: { fixture.now }
        )

        let live = await liveInputs.loadContinuousBatchingPolicy(
            candidateCatalog: fixture.catalog,
            baseURL: baseURL
        )
        XCTAssertEqual(live.status, .liveVerified)
        XCTAssertEqual(live.signerKeyID, fixture.keyID)
        XCTAssertTrue(live.selection.acceptanceCoverage.covers(fixture.requestedTuple))

        let absentInputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.fileDoesNotExist) },
            trustedPublicKeys: fixture.trustedKeyring.publicKeysByKeyID,
            now: { fixture.now }
        )
        let absent = await absentInputs.loadContinuousBatchingPolicy(
            candidateCatalog: fixture.catalog,
            baseURL: baseURL
        )
        XCTAssertEqual(absent.status, .absentFallback)
        XCTAssertFalse(absent.selection.acceptanceCoverage.covers(fixture.requestedTuple))
    }

    private struct Fixture {
        let now: Date
        let signer: Curve25519.Signing.PrivateKey
        let keyID: String
        let trustedKeyring: ContinuousBatchingSignedPolicy.TrustedKeyring
        let catalog: AutotuneStaticSelection<CandidateCatalog>
        let policyData: Data
        let signatureData: Data
        let requestedTuple: ContinuousBatchingRequestedTuple
    }

    private func makeFixture(
        generatedAt: String = "2026-09-30T00:00:00Z",
        catalogGeneratedAt: String? = nil,
        expiresAt: String = "2026-10-30T00:00:00Z",
        cacheClass: String = "KVCacheSimple",
        recomputeTuple: Bool = true,
        mutate: ((inout [String: Any]) -> Void)? = nil,
        mutateRoot: ((inout [String: Any]) -> Void)? = nil
    ) throws -> Fixture {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T01:00:00Z"))
        let signer = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-test"
        let trustedKeyring = ContinuousBatchingSignedPolicy.TrustedKeyring(
            publicKeysByKeyID: [keyID: signer.publicKey.rawRepresentation.base64EncodedString()],
            requiredKeyID: keyID
        )
        let catalogJSON = Data("""
        {
          "version": "published-2026-09-30-cb-test",
          "generated_at": "\(catalogGeneratedAt ?? generatedAt)",
          "source": "operator_curated_autotune_candidate_catalog",
          "policy_version": "autotune-policy-v1",
          "rows": {
            "qwen/qwen3.5-27b": {
              "model_id": "mlx-community/Qwen3.5-27B-4bit",
              "model_revision": "\(String(repeating: "a", count: 40))",
              "model_sha256": "\(String(repeating: "b", count: 64))",
              "min_ram_gb": 64,
              "min_bandwidth_tier": "S",
              "bench_gate": {
                "min_sustained_tps": 1.0,
                "max_4k_ttft_ms": 1000,
                "provenance": {"source": "policy"}
              },
              "runtime_status": "recommendable"
            }
          }
        }
        """.utf8)
        let catalogValue = try AutotuneStaticInputs.decodeCandidateCatalog(catalogJSON)
        let catalog = AutotuneStaticSelection(
            value: catalogValue,
            selectedBytes: catalogJSON,
            warnings: [],
            usedFallback: false,
            signerKeyID: keyID
        )
        let catalogSHA256 = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalogJSON)
        var entry: [String: Any] = [
            "model_key": "qwen/qwen3.5-27b",
            "model_id": "qwen/qwen3.5-27b",
            "model_sha256": String(repeating: "b", count: 64),
            "tokenizer_sha256": String(repeating: "c", count: 64),
            "chat_template_sha256": String(repeating: "d", count: 64),
            "cache_class": cacheClass,
            "kv_dtype": "fp16",
            "requires_moe": false,
            "hardware_class": "apple-silicon:m4-max:ram-64gb",
            "metallib_sha256": String(repeating: "e", count: 64),
            "kernel_identifier": "macprovider_paged_kv_gather_v1",
            "rollout": "on",
            "cached_turns_accepted": true,
            "provenance": [
                "source": "packaged_studio_campaign",
                "status": "qualified",
                "evidence_id": "studio-cb-qwen35-27b-2026-09-30",
                "package_manifest_sha256": String(repeating: "5", count: 64),
                "studio_campaign_sha256": String(repeating: "6", count: 64),
                "provider_cli_version": "1.8.208-candidate",
                "live_executable_cdhash": String(repeating: "7", count: 40),
            ],
        ]
        let originalTupleSHA256 = try ContinuousBatchingSignedPolicy.tupleSHA256(
            releaseID: "published-2026-09-30-cb-test",
            policyVersion: "autotune-policy-v1",
            generatedAt: generatedAt,
            expiresAt: expiresAt,
            candidateCatalogSHA256: catalogSHA256,
            signerKeyID: keyID,
            entry: entry
        )
        entry["tuple_sha256"] = originalTupleSHA256
        mutate?(&entry)
        if recomputeTuple {
            entry["tuple_sha256"] = try ContinuousBatchingSignedPolicy.tupleSHA256(
                releaseID: "published-2026-09-30-cb-test",
                policyVersion: "autotune-policy-v1",
                generatedAt: generatedAt,
                expiresAt: expiresAt,
                candidateCatalogSHA256: catalogSHA256,
                signerKeyID: keyID,
                entry: entry
            )
        }
        var root: [String: Any] = [
            "schema_version": ContinuousBatchingSignedPolicy.schemaVersion,
            "release_id": "published-2026-09-30-cb-test",
            "policy_version": "autotune-policy-v1",
            "generated_at": generatedAt,
            "expires_at": expiresAt,
            "candidate_catalog_sha256": catalogSHA256,
            "signer_key_id": keyID,
            "entries": [entry],
        ]
        mutateRoot?(&root)
        let policyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let requestedTuple = ContinuousBatchingRequestedTuple(
            modelID: "qwen/qwen3.5-27b",
            modelSHA256: String(repeating: "b", count: 64),
            tokenizerSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64),
            cacheClass: cacheClass,
            kvDType: .fp16,
            requiresMoE: false,
            hardwareClass: "apple-silicon:m4-max:ram-64gb",
            metallibSHA256: String(repeating: "e", count: 64),
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "parity",
            poolEpoch: 1
        )
        return Fixture(
            now: now,
            signer: signer,
            keyID: keyID,
            trustedKeyring: trustedKeyring,
            catalog: catalog,
            policyData: policyData,
            signatureData: signatureData(payload: policyData, signer: signer, keyID: keyID),
            requestedTuple: requestedTuple
        )
    }

    private func signatureData(
        payload: Data,
        signer: Curve25519.Signing.PrivateKey,
        keyID: String
    ) -> Data {
        let signature = try! signer.signature(for: payload).base64EncodedString()
        return Data(#"{"alg":"ed25519","key_id":"\#(keyID)","signature":"\#(signature)"}"#.utf8)
    }
}
