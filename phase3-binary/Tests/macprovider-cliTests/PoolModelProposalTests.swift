import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// #1816 `models propose`: the closed `pool_model_proposal.v1` bundle.
final class PoolModelProposalTests: XCTestCase {
    private static let poolID = "AbCdEfGhIjKlMnOpQrStUv"
    private static let hash = String(repeating: "a", count: 64)

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func candidate(
        runtimeSource: String = "llamacpp_loopback",
        servedModelRef: String = "llamacpp:My_Model-Q4.gguf",
        displayName: String = "My_Model Q4 (GGUF)",
        catalogModelKey: String? = nil,
        contextWindowTokens: Int? = 32768
    ) -> BYOMDiscoveryWire.Candidate {
        BYOMDiscoveryWire.Candidate(
            candidateID: "byom_" + String(repeating: "b", count: 52),
            runtimeSource: runtimeSource,
            displayName: displayName,
            servedModelRef: servedModelRef,
            catalogModelKey: catalogModelKey,
            identityState: "artifact_hash_available",
            locality: "local",
            estimatedGB: nil,
            contextWindowTokens: contextWindowTokens,
            capabilities: .unknown,
            readinessState: "ready",
            fitState: "fits",
            evaluationState: "not_evaluated",
            admissionState: "offerable",
            admissionStateSource: "local_default",
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: "offerable", warnings: []),
            warningCodes: []
        )
    }

    private static func object(_ bundle: PoolModelProposalWire) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ModelSwitchingWireCodec.encode(bundle).utf8)) as? [String: Any])
    }

    func testBundleIsClosedAndCarriesTheEntryFields() throws {
        let bundle = try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID,
            slug: nil,
            providerID: "provider-a",
            candidate: Self.candidate(),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash],
            pricing: try PoolModelProposalBuilder.pricing(prompt: 100, cacheHit: 10, completion: 400),
            evaluationDigestSHA256: nil,
            offerStatus: nil,
            generatedAt: "2026-10-01T00:00:00Z",
            cliVersion: "test"
        )
        let object = try Self.object(bundle)
        XCTAssertEqual(Set(object.keys), [
            "schema", "generated_at", "cli_version", "pool_id", "provider_id", "candidate_id", "served_model_ref",
            "runtime_source", "display_name", "catalog_model_key", "model_entry", "creator_requirements", "evidence",
            "offer_status", "warnings",
        ])
        XCTAssertEqual(object["schema"] as? String, "pool_model_proposal.v1")
        XCTAssertTrue(object["catalog_model_key"] is NSNull, "the no-catalog case carries an explicit null")
        XCTAssertTrue(object["offer_status"] is NSNull)
        let entry = try XCTUnwrap(object["model_entry"] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), [
            "pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
            "paid_serving_attested", "pricing", "disclosure_class", "max_context_tokens",
        ])
        XCTAssertEqual(entry["pool_model_id"] as? String, "pool/\(Self.poolID)/my-model-q4-gguf")
        XCTAssertNotNil((entry["pool_model_id"] as? String)?.range(of: BYOMAdmissionStatusWire.poolModelIDPattern, options: .regularExpression))
        XCTAssertEqual(entry["artifact_hash_algorithm"] as? String, "macprovider.gguf-file.v1")
        XCTAssertEqual(entry["artifact_hash"] as? String, Self.hash)
        XCTAssertEqual(entry["allowed_runtime_sources"] as? [String], ["llamacpp_loopback"])
        XCTAssertTrue(entry["license"] is NSNull, "the creator supplies the licence")
        XCTAssertTrue(entry["paid_serving_attested"] is NSNull, "the creator signs paid serving")
        XCTAssertEqual(entry["disclosure_class"] as? String, "pool_attested_unverified")
        XCTAssertEqual(entry["max_context_tokens"] as? Int, 32768)
        let pricing = try XCTUnwrap(entry["pricing"] as? [String: Any])
        XCTAssertEqual(Set(pricing.keys), ["prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok"])
        XCTAssertEqual(pricing["completion_rate_per_mtok"] as? Int, 400)
        let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertEqual(Set(evidence.keys), ["evaluation_digest_sha256", "known_answer_probe_evidence_sha256"])
        XCTAssertEqual(object["creator_requirements"] as? [String], [
            "license_spdx_or_licenseref_required",
            "paid_serving_attested_must_be_true",
            "pricing_must_be_within_pool_model_bounds",
            "runtime_source_in_runtime_allowlist",
            "attested_member_required_for_non_creator_account",
        ])
        XCTAssertEqual(object["warnings"] as? [String], ["offer_not_submitted"])
    }

    /// #1816: the lab creator tool (`scripts/lab/1690-m6/pool_setup.py entry`)
    /// and the coordinator-cli signer test both consume a fixture of this
    /// bundle; it must stay exactly the CLI's closed shape.
    func testLabProposalFixtureMatchesTheBundleShape() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/lab/1690-m6/testdata/pool_model_proposal.v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let object = try Self.object(try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: "provider-a", candidate: Self.candidate(),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash],
            pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        ))
        XCTAssertEqual(Set(fixture.keys), Set(object.keys))
        XCTAssertEqual(fixture["schema"] as? String, PoolModelProposalWire.schemaID)
        let fixtureEntry = try XCTUnwrap(fixture["model_entry"] as? [String: Any])
        let entry = try XCTUnwrap(object["model_entry"] as? [String: Any])
        XCTAssertEqual(Set(fixtureEntry.keys), Set(entry.keys))
        XCTAssertTrue(fixtureEntry["license"] is NSNull && entry["license"] is NSNull)
        XCTAssertTrue(fixtureEntry["paid_serving_attested"] is NSNull && entry["paid_serving_attested"] is NSNull)
        let fixtureEvidence = try XCTUnwrap(fixture["evidence"] as? [String: Any])
        let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertEqual(Set(fixtureEvidence.keys), Set(evidence.keys))
        let codes = Set(PoolModelProposalWire.Requirement.allCases.map(\.rawValue))
        XCTAssertTrue(Set(try XCTUnwrap(fixture["creator_requirements"] as? [String])).isSubset(of: codes))
    }

    /// Freeze audit R1 (#1816) CODE M6: a native mlx_cache proposal asks for
    /// no loopback-only control (runtime_allowlist, R016 attestation); an
    /// MLX loopback proposal still does.
    func testNativeProposalOmitsLoopbackOnlyRequirements() throws {
        func requirements(_ runtime: String) throws -> [String] {
            try PoolModelProposalBuilder.makeBundle(
                poolID: Self.poolID, slug: "qwen-local", providerID: nil,
                candidate: Self.candidate(runtimeSource: runtime),
                artifactHashes: [ModelArtifactIdentity.snapshotManifestV1: Self.hash],
                pricing: try PoolModelProposalBuilder.pricing(prompt: 100, cacheHit: 10, completion: 400),
                evaluationDigestSHA256: nil, offerStatus: nil
            ).creatorRequirements
        }
        XCTAssertEqual(try requirements("mlx_cache"), [
            "license_spdx_or_licenseref_required",
            "paid_serving_attested_must_be_true",
            "pricing_must_be_within_pool_model_bounds",
        ])
        XCTAssertEqual(try requirements("mlxlm_loopback"), [
            "license_spdx_or_licenseref_required",
            "paid_serving_attested_must_be_true",
            "pricing_must_be_within_pool_model_bounds",
            "runtime_source_in_runtime_allowlist",
            "attested_member_required_for_non_creator_account",
        ])
    }

    /// Freeze audit R1 (#1816) CODE M7: a missing or malformed explicit
    /// config is an error; the command never falls back to the production
    /// coordinator feed for it.
    func testExplicitConfigErrorsNeverFallBackToProduction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try BYOMLiveCatalogMatcher.configuredCoordinatorURL(configPath: dir.appendingPathComponent("missing.yaml").path))
        let malformed = dir.appendingPathComponent("malformed.yaml")
        try "coordinator_url: [unclosed\n".write(to: malformed, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BYOMLiveCatalogMatcher.configuredCoordinatorURL(configPath: malformed.path))
        let mistyped = dir.appendingPathComponent("mistyped.yaml")
        try "coordinator_url: 42\n".write(to: mistyped, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BYOMLiveCatalogMatcher.configuredCoordinatorURL(configPath: mistyped.path))
        let staging = dir.appendingPathComponent("staging.yaml")
        try "coordinator_url: wss://staging.example.test/ws\n".write(to: staging, atomically: true, encoding: .utf8)
        XCTAssertEqual(try BYOMLiveCatalogMatcher.configuredCoordinatorURL(configPath: staging.path), "wss://staging.example.test/ws")
    }

    func testRuntimeAlgorithmPairsAndFailClosedInputs() throws {
        // Native MLX and the MLX loopbacks name snapshot-manifest entries.
        for runtime in ["mlx_cache", "mlxlm_loopback", "omlx_loopback"] {
            let bundle = try PoolModelProposalBuilder.makeBundle(
                poolID: Self.poolID, slug: "qwen-local", providerID: nil,
                candidate: Self.candidate(runtimeSource: runtime, contextWindowTokens: nil),
                artifactHashes: [ModelArtifactIdentity.snapshotManifestV1: Self.hash],
                pricing: nil, evaluationDigestSHA256: Self.hash, offerStatus: nil
            )
            XCTAssertEqual(bundle.modelEntry.artifactHashAlgorithm, ModelArtifactIdentity.snapshotManifestV1)
            XCTAssertEqual(bundle.modelEntry.poolModelID, "pool/\(Self.poolID)/qwen-local")
            XCTAssertNil(bundle.modelEntry.maxContextTokens)
            XCTAssertTrue(bundle.creatorRequirements.contains("pricing_required_within_pool_model_bounds"))
            XCTAssertTrue(bundle.creatorRequirements.contains("max_context_tokens_required"))
            XCTAssertEqual(bundle.evidence.evaluationDigestSHA256, Self.hash)
        }
        // A GGUF hash never stands in for a snapshot entry, and vice versa.
        XCTAssertThrowsError(try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: nil, candidate: Self.candidate(runtimeSource: "mlx_cache"),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash], pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )) { XCTAssertEqual($0 as? PoolModelProposalError, .artifactHashUnavailable("mlx_cache")) }
        XCTAssertThrowsError(try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: nil, candidate: Self.candidate(),
            artifactHashes: [:], pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )) { XCTAssertEqual($0 as? PoolModelProposalError, .artifactHashUnavailable("llamacpp_loopback")) }
        // No artifact identity a pool entry can name.
        XCTAssertThrowsError(try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: nil, candidate: Self.candidate(runtimeSource: "openai_compatible_loopback"),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash], pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )) { XCTAssertEqual($0 as? PoolModelProposalError, .runtimeNotPoolEligible("openai_compatible_loopback")) }
        for bad in ["short", "AbCdEfGhIjKlMnOpQrStU!", "pool/AbCdEfGhIjKlMnOpQrStUv"] {
            XCTAssertThrowsError(try PoolModelProposalBuilder.validatePoolID(bad), bad)
        }
        XCTAssertThrowsError(try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: "Bad_Slug", providerID: nil, candidate: Self.candidate(),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash], pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )) { XCTAssertEqual($0 as? PoolModelProposalError, .invalidSlug) }
        XCTAssertNil(try PoolModelProposalBuilder.pricing(prompt: nil, cacheHit: nil, completion: nil))
        XCTAssertThrowsError(try PoolModelProposalBuilder.pricing(prompt: 10, cacheHit: nil, completion: 10))
        XCTAssertThrowsError(try PoolModelProposalBuilder.pricing(prompt: 10, cacheHit: 11, completion: 10))
        XCTAssertThrowsError(try PoolModelProposalBuilder.pricing(prompt: -1, cacheHit: 0, completion: 10))
        // A catalog-matched candidate already has the catalog path: warned.
        let catalogMatched = try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: nil, candidate: Self.candidate(catalogModelKey: "qwen3-8b"),
            artifactHashes: [ModelArtifactIdentity.ggufFileV1: Self.hash], pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )
        XCTAssertTrue(catalogMatched.warnings.contains("candidate_catalog_matched"))
    }

    func testSlugIsDerivedDeterministically() {
        XCTAssertEqual(PoolModelProposalBuilder.suggestedSlug(for: Self.candidate(displayName: "  ")), "llamacpp-my-model-q4-gguf")
        XCTAssertEqual(PoolModelProposalBuilder.suggestedSlug(for: Self.candidate(servedModelRef: "llamacpp:模型", displayName: "日本語")), "llamacpp")
        XCTAssertEqual(PoolModelProposalBuilder.suggestedSlug(for: Self.candidate(servedModelRef: "模型", displayName: "日本語")), "model")
        let long = PoolModelProposalBuilder.suggestedSlug(for: Self.candidate(displayName: String(repeating: "ab-", count: 40)))
        XCTAssertLessThanOrEqual(long.count, 63)
        XCTAssertNotNil(long.range(of: PoolModelProposalBuilder.slugPattern, options: .regularExpression))
    }

    /// End to end over a fake Ollama store: the bundle's hash is the CLI's own
    /// digest of the complete file bytes, never the store's locator.
    func testReadOnlyProposalHashesTheServedFileBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-propose-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let blob = Data("GGUF".utf8) + Data(repeating: 0xcd, count: 8192)
        let locator = String(repeating: "7", count: 64)
        let blobURL = root.appendingPathComponent("blobs/sha256-\(locator)")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: blobURL)
        let manifestURL = root.appendingPathComponent("manifests/registry.ollama.ai/library/local-model/q4")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:\(String(repeating: "0", count: 64))","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\(locator)","size":\(blob.count)}]}
        """.utf8).write(to: manifestURL)
        let environment = BYOMDiscoveryEnvironment(
            namespaceURL: root.appendingPathComponent("ns/local_discovery_namespace"),
            mlxCacheRoot: root.appendingPathComponent("mlx"),
            ollamaOrigin: "http://127.0.0.1:11434",
            lmstudioOrigin: nil,
            llamacppOrigin: nil,
            ollamaModelsRoot: root,
            artifactDigestCacheURL: root.appendingPathComponent("cache/digests.json")
        )
        let tags = Data(#"{"models":[{"name":"local-model:q4","details":{"family":"llama","quantization_level":"Q4_K_M"}}]}"#.utf8)
        let runtime = BYOMModelAdmissionRuntime(
            environment: environment,
            client: nil,
            httpClient: ProposalStubHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: tags))
        )
        let candidate = try await runtime.resolveOfferCandidate("local-model:q4")
        XCTAssertEqual(candidate.runtimeSource, "ollama_loopback")
        XCTAssertTrue(candidate.candidateID.hasPrefix("byom_"))
        XCTAssertFalse(candidate.candidateID.hasPrefix("byom_unstable_"))
        let artifact = try await runtime.offerArtifact(for: candidate, servedArtifactPath: nil, servedModelID: nil)
        let bundle = try PoolModelProposalBuilder.makeBundle(
            poolID: Self.poolID, slug: nil, providerID: nil, candidate: candidate,
            artifactHashes: artifact.hashes, pricing: nil, evaluationDigestSHA256: nil, offerStatus: nil
        )
        XCTAssertEqual(bundle.modelEntry.artifactHash, Self.sha256Hex(blob))
        XCTAssertNotEqual(bundle.modelEntry.artifactHash, locator)
        XCTAssertEqual(bundle.modelEntry.allowedRuntimeSources, ["ollama_loopback"])
        XCTAssertNil(bundle.catalogModelKey)
        XCTAssertNil(bundle.offerStatus)
    }
}

private struct ProposalStubHTTPClient: BYOMDiscoveryHTTPClient {
    let response: BYOMHTTPResponse
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse { response }
    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse { response }
}
