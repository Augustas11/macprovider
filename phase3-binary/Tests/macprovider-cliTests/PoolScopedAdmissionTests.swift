import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// #1816: pool-scoped status readback (SPEC-047-R011) and the live signed
/// artifact feed behind the BYOM catalog matcher.
final class PoolScopedAdmissionTests: XCTestCase {
    static let poolID = "AbCdEfGhIjKlMnOpQrStUv"
    static let poolModelID = "pool/AbCdEfGhIjKlMnOpQrStUv/my-model"
    static let candidateID = "byom_" + String(repeating: "a", count: 52)

    static func poolBindingObject() -> [String: Any] {
        // Exactly the coordinator's modelAdmissionPoolBindingObject key set.
        [
            "binding_scope": "pool",
            "pool_id": poolID,
            "pool_model_id": poolModelID,
            "manifest_version": 3,
            "manifest_core_digest": String(repeating: "c", count: 64),
            "artifact_hash_algorithm": "macprovider.gguf-file.v1",
            "artifact_hash": String(repeating: "d", count: 64),
            "runtime_source": "llamacpp_loopback",
            "prompt_rate_per_mtok": 100,
            "prompt_cache_hit_rate_per_mtok": 10,
            "completion_rate_per_mtok": 400,
            "disclosure_class": "pool_attested_unverified",
            "max_context_tokens": 32768,
            "provider_account_id": "acct-creator",
            "observed_catalog_model_key": NSNull(),
            "probe_evidence_digest": NSNull(),
        ]
    }

    static func statusObject(
        state: String = "catalog_priced",
        catalogModelKey: Any = NSNull(),
        nextAction: String = "withdraw",
        earningPath: String = "pool_attested_earning",
        topLevelScope: Any? = nil,
        binding: Any? = poolBindingObject()
    ) -> [String: Any] {
        var object: [String: Any] = [
            "schema": "model_admission_status.v1",
            "generated_at": "2026-10-01T00:00:00Z",
            "cli_version": "1.8.207",
            "provider_id": "provider-a",
            "candidate_id": candidateID,
            "served_model_ref": "llamacpp:my-model",
            "catalog_model_key": catalogModelKey,
            "admission_state": state,
            "admission_state_source": "coordinator",
            "coordinator_event_id": "evt-1",
            "state_observed_at": "2026-10-01T00:00:00Z",
            "provider_guidance": [
                "state_label_key": "byom.admission." + state,
                "state_meaning_key": "byom.admission.not_earning",
                "next_action": nextAction,
                "transition_reason_code": NSNull(),
                "earning_path_class": earningPath,
            ],
            "allowed_next_states": ["withdrawn", "revoked"],
            "warnings": [],
        ]
        if let topLevelScope { object["binding_scope"] = topLevelScope }
        if let binding { object["pool_binding"] = binding }
        return object
    }

    private func decode(_ object: [String: Any]) throws -> BYOMAdmissionStatusWire {
        try BYOMAdmissionStatusWire.decodeStrictStatus(
            from: JSONSerialization.data(withJSONObject: object),
            expectedProviderID: "provider-a",
            expectedCandidateID: Self.candidateID
        )
    }

    func testPoolScopedCatalogPricedDecodesAndRoundTrips() throws {
        let status = try decode(Self.statusObject())
        XCTAssertTrue(status.isPoolScoped)
        XCTAssertNil(status.catalogModelKey)
        XCTAssertEqual(status.poolBinding?.poolModelID, Self.poolModelID)
        XCTAssertEqual(status.poolBinding?.completionRatePerMtok, 400)
        XCTAssertEqual(status.poolBinding?.manifestCoreDigest, String(repeating: "c", count: 64))
        XCTAssertEqual(status.poolBinding?.providerAccountID, "acct-creator")
        XCTAssertNil(status.poolBinding?.observedCatalogModelKey)
        XCTAssertEqual(status.providerGuidance.earningPathClass, "pool_attested_earning")
        let encoded = Data(try ModelSwitchingWireCodec.encode(status).utf8)
        XCTAssertEqual(try BYOMAdmissionStatusWire.decodeStrictStatus(from: encoded), status)
        // The same binding while a pool predicate does not hold discloses no
        // earning path, and maintain_runtime is accepted for the pool edge.
        XCTAssertNoThrow(try decode(Self.statusObject(earningPath: "no_earning_path_in_v0_1")))
        XCTAssertNoThrow(try decode(Self.statusObject(nextAction: "maintain_runtime")))
        // A snapshot-manifest entry may bind native mlx_cache.
        var mlx = Self.poolBindingObject()
        mlx["artifact_hash_algorithm"] = "macprovider.snapshot-manifest.v1"
        mlx["runtime_source"] = "mlx_cache"
        XCTAssertNoThrow(try decode(Self.statusObject(binding: mlx)))
        // The nullable audit fields round-trip when set, and stay present as
        // explicit nulls when not.
        var audited = Self.poolBindingObject()
        audited["observed_catalog_model_key"] = "qwen3-8b"
        audited["probe_evidence_digest"] = String(repeating: "e", count: 64)
        let auditedStatus = try decode(Self.statusObject(binding: audited))
        XCTAssertEqual(auditedStatus.poolBinding?.observedCatalogModelKey, "qwen3-8b")
        XCTAssertEqual(try BYOMAdmissionStatusWire.decodeStrictStatus(
            from: Data(try ModelSwitchingWireCodec.encode(auditedStatus).utf8)
        ), auditedStatus)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try ModelSwitchingWireCodec.encode(status).utf8)
        ) as? [String: Any])
        let reencodedBinding = try XCTUnwrap(reencoded["pool_binding"] as? [String: Any])
        XCTAssertEqual(Set(reencodedBinding.keys), BYOMAdmissionStatusWire.PoolBinding.keys)
        XCTAssertTrue(reencodedBinding["probe_evidence_digest"] is NSNull)
        XCTAssertNil(reencoded["binding_scope"])
    }

    /// #1816 F1: the coordinator's own `modelAdmissionStatusResponseFromEvent`
    /// bytes (generated by the Go test
    /// TestSPEC047PoolScopedStatusSharedFixture) decode strictly, so the CLI
    /// and the coordinator are pinned to the same fixture.
    static func sharedCoordinatorStatuses() throws -> (providerID: String, statuses: [String: [String: Any]]) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("testdata/spec047/pool_scoped_status_v1.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (try XCTUnwrap(root["provider_id"] as? String), try XCTUnwrap(root["statuses"] as? [String: [String: Any]]))
    }

    func testSharedCoordinatorStatusFixtureDecodes() throws {
        let fixture = try Self.sharedCoordinatorStatuses()
        XCTAssertEqual(Set(fixture.statuses.keys), ["pool_scoped_catalog_priced", "pool_scoped_revoked", "global_offer_submitted"])
        for (name, object) in fixture.statuses {
            let candidateID = try XCTUnwrap(object["candidate_id"] as? String)
            XCTAssertNoThrow(try BYOMAdmissionStatusWire.decodeStrictStatus(
                from: JSONSerialization.data(withJSONObject: object),
                expectedProviderID: fixture.providerID,
                expectedCandidateID: candidateID
            ), name)
        }
        let priced = try BYOMAdmissionStatusWire.decodeStrictStatus(
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(fixture.statuses["pool_scoped_catalog_priced"]))
        )
        XCTAssertTrue(priced.isPoolScoped)
        XCTAssertEqual(priced.allowedNextStates, ["catalog_priced", "withdrawn", "revoked"])
        XCTAssertEqual(priced.providerGuidance.earningPathClass, "pool_attested_earning")
    }

    /// The pool-scoped narrowing is accepted exactly when `pool_binding` is
    /// present: a global `catalog_priced` status never claims the self-edge,
    /// and a pool binding never widens to `settlement_capable`.
    func testPoolScopedNextStatesOnlyWithPoolBinding() throws {
        var pooled = try XCTUnwrap(Self.sharedCoordinatorStatuses().statuses["pool_scoped_catalog_priced"])
        XCTAssertNoThrow(try decodeShared(pooled))
        pooled["allowed_next_states"] = ["catalog_priced", "withdrawn", "revoked", "settlement_capable"]
        XCTAssertThrowsError(try decodeShared(pooled))
        pooled["allowed_next_states"] = ["network_admitted_unsettled"]
        XCTAssertThrowsError(try decodeShared(pooled))

        var global = try XCTUnwrap(Self.sharedCoordinatorStatuses().statuses["pool_scoped_catalog_priced"])
        global.removeValue(forKey: "pool_binding")
        global["catalog_model_key"] = "qwen3-8b"
        global["provider_guidance"] = [
            "state_label_key": "byom.admission.catalog_priced",
            "state_meaning_key": "byom.admission.not_earning",
            "next_action": "withdraw",
            "transition_reason_code": NSNull(),
            "earning_path_class": "not_earning_yet_catalog_or_receipt_path_exists",
        ]
        global["allowed_next_states"] = ["withdrawn", "revoked"]
        XCTAssertNoThrow(try decodeShared(global))
        global["allowed_next_states"] = ["catalog_priced", "withdrawn", "revoked"]
        XCTAssertThrowsError(try decodeShared(global))
    }

    private func decodeShared(_ object: [String: Any]) throws -> BYOMAdmissionStatusWire {
        try BYOMAdmissionStatusWire.decodeStrictStatus(from: JSONSerialization.data(withJSONObject: object))
    }

    func testStatusReadbackWordingIsPoolScopedAndHonest() throws {
        let earning = try XCTUnwrap(poolBindingNote(try decode(Self.statusObject())))
        XCTAssertTrue(earning.contains("eligible to earn on pool \(Self.poolID) only for qualifying settled requests"))
        XCTAssertTrue(earning.contains("Pool-attested, not network-verified"))
        XCTAssertFalse(earning.contains("earns only"))
        let idle = try XCTUnwrap(poolBindingNote(try decode(Self.statusObject(earningPath: "no_earning_path_in_v0_1"))))
        XCTAssertTrue(idle.contains("not currently eligible on this pool"))
        XCTAssertFalse(idle.contains("does not earn right now"))
        XCTAssertNil(poolBindingNote(try decode(Self.statusObject(
            catalogModelKey: "qwen3-8b",
            earningPath: "not_earning_yet_catalog_or_receipt_path_exists",
            binding: nil
        ))))
    }

    func testGlobalEnvelopeStaysByteIdenticalV1() throws {
        var object = Self.statusObject(
            catalogModelKey: "qwen3-8b",
            earningPath: "not_earning_yet_catalog_or_receipt_path_exists",
            binding: nil
        )
        let status = try decode(object)
        XCTAssertFalse(status.isPoolScoped)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try ModelSwitchingWireCodec.encode(status).utf8)
        ) as? [String: Any])
        XCTAssertNil(reencoded["binding_scope"])
        XCTAssertNil(reencoded["pool_binding"])
        // The closed v1 envelope has no top-level binding_scope: the
        // coordinator emits the scope only inside pool_binding.
        object["binding_scope"] = "global"
        XCTAssertThrowsError(try decode(object))
    }

    func testPoolScopeFailsClosed() {
        var badPricing = Self.poolBindingObject()
        badPricing["prompt_rate_per_mtok"] = 10
        badPricing["prompt_cache_hit_rate_per_mtok"] = 11
        var otherPool = Self.poolBindingObject()
        otherPool["pool_model_id"] = "pool/ZZCdEfGhIjKlMnOpQrStUv/my-model"
        var mismatchedRuntime = Self.poolBindingObject()
        mismatchedRuntime["runtime_source"] = "mlxlm_loopback"
        var extraKey = Self.poolBindingObject()
        extraKey["catalog_model_key"] = "qwen3-8b"
        var nestedPricing = Self.poolBindingObject()
        nestedPricing["pricing"] = ["prompt_rate_per_mtok": 100, "prompt_cache_hit_rate_per_mtok": 10, "completion_rate_per_mtok": 400]
        var legacyDigestName = Self.poolBindingObject()
        legacyDigestName["core_digest"] = legacyDigestName.removeValue(forKey: "manifest_core_digest")
        var globalScope = Self.poolBindingObject()
        globalScope["binding_scope"] = "global"
        var missingNullable = Self.poolBindingObject()
        missingNullable.removeValue(forKey: "probe_evidence_digest")
        var badProbeDigest = Self.poolBindingObject()
        badProbeDigest["probe_evidence_digest"] = "not-hex"
        var badDisclosure = Self.poolBindingObject()
        badDisclosure["disclosure_class"] = "network_verified"
        var badContext = Self.poolBindingObject()
        badContext["max_context_tokens"] = 0
        let rejected: [(String, [String: Any])] = [
            ("pool earning on a global binding", Self.statusObject(binding: nil)),
            ("top-level scope beside the binding", Self.statusObject(topLevelScope: "pool")),
            ("binding scoped global", Self.statusObject(earningPath: "no_earning_path_in_v0_1", binding: globalScope)),
            ("null binding", Self.statusObject(binding: NSNull())),
            ("pool binding laundered into a catalog key", Self.statusObject(catalogModelKey: "qwen3-8b")),
            ("pool binding never settlement_capable", Self.statusObject(state: "settlement_capable", nextAction: "maintain_runtime", earningPath: "settlement_capable")),
            ("pool earning outside catalog_priced", Self.statusObject(state: "network_admitted_unsettled")),
            ("cache-hit rate above prompt rate", Self.statusObject(binding: badPricing)),
            ("pool id segment differs", Self.statusObject(binding: otherPool)),
            ("gguf entry on an MLX runtime", Self.statusObject(binding: mismatchedRuntime)),
            ("extra binding key", Self.statusObject(binding: extraKey)),
            ("nested pricing object", Self.statusObject(binding: nestedPricing)),
            ("core_digest instead of manifest_core_digest", Self.statusObject(binding: legacyDigestName)),
            ("nullable key omitted", Self.statusObject(binding: missingNullable)),
            ("probe digest grammar", Self.statusObject(binding: badProbeDigest)),
            ("disclosure class", Self.statusObject(binding: badDisclosure)),
            ("max context bound", Self.statusObject(binding: badContext)),
        ]
        for (label, object) in rejected {
            XCTAssertThrowsError(try decode(object), label)
        }
    }

    // MARK: live artifact feed

    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private func liveFixture(ggufHash: String) throws -> (candidate: AutotuneStaticSelection<CandidateCatalog>, feed: QualifiedArtifactFeed) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.corpusURL)) as! [String: Any]
        let candidateBytes = try JSONSerialization.data(withJSONObject: object["candidate"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        var feed = object["feed"] as! [String: Any]
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        var models = feed["models"] as! [String: Any]
        var model = models["test-model"] as! [String: Any]
        var artifacts = model["artifacts"] as! [String: Any]
        artifacts["gguf-q4"] = [
            "allowed_runtime_sources": ["ollama_loopback"], "hash": ggufHash, "hash_algorithm": "macprovider.gguf-file.v1",
            "min_ram_gb": 4, "quantization": "q4_k_m", "runtime_format": "gguf", "size_bytes": 654321,
            "source_ref": ["digest": "sha256:" + ggufHash, "kind": "ollama_library_tag", "library_tag": "test-model:q4_k_m"],
            "verification_status": "verified", "verified_at": "2026-09-01",
        ]
        model["artifacts"] = artifacts
        models["test-model"] = model
        feed["models"] = models
        let feedBytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "streamvc-autotune-static-v4"
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        let qualified = try AutotuneStaticInputs.qualifyArtifactFeed(
            feed: try AutotuneStaticInputs.decodeArtifactFeed(feedBytes),
            bytes: feedBytes,
            signerKeyID: signer,
            catalog: catalog,
            candidateBytes: candidateBytes,
            candidateSignerKeyID: signer
        )
        return (
            AutotuneStaticSelection(value: catalog, selectedBytes: candidateBytes, warnings: [], usedFallback: false, signerKeyID: signer),
            qualified
        )
    }

    func testLiveSignedFeedIsPreferredAndCompiledInIsTheFallback() throws {
        let hash = String(repeating: "e", count: 64)
        let fixture = try liveFixture(ggufHash: hash)
        let live = BYOMLiveCatalogMatcher.select(
            candidate: fixture.candidate,
            live: AutotuneStaticSelection(value: fixture.feed, selectedBytes: Data(), warnings: [], usedFallback: false, signerKeyID: nil)
        )
        XCTAssertEqual(live.source, .liveSigned)
        XCTAssertEqual(
            live.matcher.catalogKey(for: "test-model:q4_k_m", runtimeSource: "ollama_loopback", digest: "sha256:" + hash),
            "test-model"
        )
        XCTAssertNil(live.matcher.catalogKey(for: "test-model:q4_k_m", runtimeSource: "ollama_loopback", digest: "sha256:" + String(repeating: "f", count: 64)))

        // An unusable or absent live feed falls back to the compiled-in
        // selection, which has no artifact for this fixture.
        let fallback = BYOMLiveCatalogMatcher.select(
            candidate: fixture.candidate,
            live: AutotuneStaticSelection(value: nil, selectedBytes: Data(), warnings: [.catalogArtifactFeedIntegrityFailure], usedFallback: false, signerKeyID: nil)
        )
        XCTAssertEqual(fallback.source, .compiledIn)
        XCTAssertNil(fallback.matcher.catalogKey(for: "test-model:q4_k_m", runtimeSource: "ollama_loopback", digest: "sha256:" + hash))
    }

    func testOfflineAndUnreachableFeedsUseTheCompiledInSelection() async {
        let neverFetch = AutotuneStaticInputs(fetch: { url in
            XCTFail("offline selection fetched \(url)")
            throw URLError(.notConnectedToInternet)
        })
        let offline = await BYOMLiveCatalogMatcher.resolve(offline: true, coordinatorURL: nil, inputs: neverFetch)
        XCTAssertEqual(offline.source, .compiledIn)

        let unreachable = AutotuneStaticInputs(fetch: { _ in throw URLError(.cannotConnectToHost) })
        let resolved = await BYOMLiveCatalogMatcher.resolve(offline: false, coordinatorURL: "wss://coordinator.example", inputs: unreachable)
        XCTAssertEqual(resolved.source, .compiledIn)
    }
}
