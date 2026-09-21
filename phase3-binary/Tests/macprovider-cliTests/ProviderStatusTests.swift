import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ProviderStatusTests: XCTestCase {
    private struct FixedMemoryPressureProvider: MemoryPressureProviding {
        let value: ProviderMemoryPressure
        func currentMemoryPressure() -> ProviderMemoryPressure { value }
    }

    private struct FixedWorkloadTelemetryProvider: ProviderWorkloadTelemetryProviding {
        let value: ProviderWorkloadTelemetry
        func currentWorkloadTelemetry() -> ProviderWorkloadTelemetry { value }
    }

    private struct Build1LaneAStatusFixture {
        let durableRoot: URL
        let binding: Build1LaneAStatusArtifactBinding
    }

    private func makeCapacity(maxConcurrency: Int = 4) -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: maxConcurrency)
    }

    private func makeBuild1LaneAStatusFixture(payload: String) throws -> Build1LaneAStatusFixture {
        let durableRoot = try tempDir()
        let stagingRoot = try tempDir()
        let weightURL = stagingRoot.appendingPathComponent("weights.bin")
        try Data(payload.utf8).write(to: weightURL, options: .atomic)

        let artifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: stagingRoot)
        let durableStore = DurableModelArtifactStore(root: durableRoot)
        _ = try durableStore.adoptVerifiedStaging(
            staging: stagingRoot,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            sha256: artifactSHA256
        )
        let binding = try recordBuild1LaneAStatusBinding(
            durableRoot: durableRoot,
            artifactSHA256: artifactSHA256,
            adoptedBytes: Int64(payload.utf8.count),
            releaseID: "test-release"
        )
        return Build1LaneAStatusFixture(durableRoot: durableRoot, binding: binding)
    }

    private func recordBuild1LaneAStatusBinding(
        durableRoot: URL,
        artifactSHA256: String,
        adoptedBytes: Int64,
        releaseID: String,
        declaredSizeBytes: Int? = nil
    ) throws -> Build1LaneAStatusArtifactBinding {
        let authority = Build1LaneAArtifactAuthority(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            hashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            hash: artifactSHA256,
            sizeBytes: declaredSizeBytes ?? Int(adoptedBytes),
            feedSHA256: String(repeating: "d", count: 64),
            feedSignerKeyID: "test-signer",
            releaseID: releaseID
        )
        let recorder = Build1LaneAPreparationRecorder(durableRoot: durableRoot)
        let session = try recorder.open()
        defer { session.close() }
        _ = try session.record(
            authority: authority,
            adoptedSHA256: authority.hash,
            adoptedBytes: adoptedBytes
        )
        return try XCTUnwrap(
            recorder.readStatusArtifactBinding(
                catalogKey: Build1LaneAPrepareProfile.catalogKey,
                expectedArtifactSHA256: authority.hash,
                expectedReleaseID: authority.releaseID
            )
        )
    }

    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-provider-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removePublishedInventory(from durableRoot: URL) throws {
        let inventory = durableRoot
            .appendingPathComponent(Build1LaneAPreparationRecorder.authorityLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.stateLeaf, isDirectory: true)
            .appendingPathComponent("published-inventory.json")
        try FileManager.default.removeItem(at: inventory)
    }

    private func removeReceipt(from durableRoot: URL, artifactIdentityDigest: String) throws {
        let receipt = durableRoot
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.objectsLeaf, isDirectory: true)
            .appendingPathComponent(artifactIdentityDigest, isDirectory: true)
            .appendingPathComponent(Build1LaneAPreparationRecorder.receiptLeaf)
        try FileManager.default.removeItem(at: receipt)
    }

    func testPausedAndDrainingStatesAtomicallyFenceNewRequests() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())

        let beforePause = await status.beginRequestIfAccepting(requestID: "before-pause")
        XCTAssertNotNil(beforePause)
        await status.setState(.draining, reason: "operator_pause_draining")
        let duringDrain = await status.beginRequestIfAccepting(requestID: "during-drain")
        XCTAssertNil(duringDrain)
        let draining = await status.snapshot()
        XCTAssertEqual(draining.requestsInFlight, 1)

        await status.finishRequest(startedAt: Date(), completion: nil, failed: false, requestID: "before-pause")
        await status.setState(.unavailable, reason: "operator_paused")
        let whilePaused = await status.beginRequestIfAccepting(requestID: "while-paused")
        let drained = await status.waitUntilDrained(timeoutSeconds: 0)
        XCTAssertNil(whilePaused)
        XCTAssertTrue(drained)
    }

    func testStatusResponseExposesOnlyRedactedCredentialLifecycleState() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snap = await status.snapshot()
        let body = RouterHandler.statusResponse(
            snap,
            providerID: "provider-a",
            coordinatorURL: nil,
            credentialStatus: ProviderCredentialStatus(
                source: .cliKeychain,
                state: .ready,
                restartSafe: true,
                migrationPending: true
            )
        )

        let credential = try XCTUnwrap(body["credential"] as? [String: Any])
        XCTAssertEqual(credential["source"] as? String, "cli_keychain")
        XCTAssertEqual(credential["state"] as? String, "ready")
        XCTAssertEqual(credential["restart_safe"] as? Bool, true)
        XCTAssertEqual(credential["migration_pending"] as? Bool, true)
        XCTAssertNil(credential["token"])
        XCTAssertFalse(String(describing: body).contains("provider_token"))
    }

    func testStatusResponseSurfacesModelLivenessTokenAndCapability() async throws {
        // SPEC-025 §5.2: /v1/status exposes the model_liveness object and advertises
        // model_liveness_token_v1. Assert structure/types (the shared tracker's
        // numeric values are process-global and not fixed across tests).
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snap = await status.snapshot()
        let body = RouterHandler.statusResponse(snap, providerID: "provider-a", coordinatorURL: nil)

        let contract = try XCTUnwrap(body["local_status_contract"] as? [String: Any])
        let capabilities = try XCTUnwrap(contract["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("model_liveness_token_v1"))
        XCTAssertTrue(capabilities.contains("build1_lane_a_status_evidence.v1"))

        let liveness = try XCTUnwrap(body["model_liveness"] as? [String: Any])
        XCTAssertNotNil(liveness["token"] as? NSNumber, "token must be a number")
        XCTAssertNotNil(liveness["active_inference"] as? Bool, "active_inference must be a bool")
        // Age fields and last_advanced_at are present but may be JSON null before
        // any progress; assert the keys exist.
        XCTAssertTrue(liveness.keys.contains("token_age_ms"))
        XCTAssertTrue(liveness.keys.contains("active_inference_age_ms"))
        XCTAssertTrue(liveness.keys.contains("last_advanced_at"))
    }

    func testStatusResponsePublishesVersionedLocalCapabilityContract() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snapshot = await status.snapshot()
        let persistedLifecycle = try ProviderLifecycleStateRecord.make(
            previous: nil,
            state: .servingBuyers,
            reasonCode: "coordinator_buyer_serving_confirmed",
            writer: .serve,
            providerID: "provider-a",
            modelID: "m",
            compatibilitySetID: "set-a",
            operationID: "serve-a",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: nil,
            admissionIdentityStatus: ProviderAdmissionIdentityStatusContext(
                source: "cli_keychain",
                state: "degraded_previous_key",
                publicKeySHA256: String(repeating: "a", count: 64),
                pendingPublicKeySHA256: String(repeating: "b", count: 64),
                previousPublicKeySHA256: String(repeating: "c", count: 64),
                previousValidUntil: "2026-07-21T12:00:00.000Z",
                coordinatorGeneration: 3,
                coordinatorPublicKeySHA256: String(repeating: "d", count: 64),
                coordinatorKeyRole: "previous",
                transitionError: "coordinator_previous_key_grace",
                recoveryAction: "restore_current_key_or_run_recover_admission_identity"
            ),
            lifecycleStateInspection: .valid(persistedLifecycle)
        )

        let contract = try XCTUnwrap(body["local_status_contract"] as? [String: Any])
        XCTAssertEqual(contract["version"] as? Int, 1)
        XCTAssertEqual(contract["minimum_reader_version"] as? Int, 1)
        XCTAssertEqual(contract["lifecycle_owner"] as? String, "macprovider_cli")
        let capabilities = try XCTUnwrap(contract["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("buyer_serving_authority_v1"))
        XCTAssertTrue(capabilities.contains("catalog_status_v1"))
        XCTAssertTrue(capabilities.contains("compatibility_set_v1"))
        XCTAssertTrue(capabilities.contains("credential_status_v1"))
        XCTAssertTrue(capabilities.contains("admission_identity_v1"))
        XCTAssertTrue(capabilities.contains("lifecycle_lease_v1"))
        XCTAssertTrue(capabilities.contains("lifecycle_transition_v1"))
        XCTAssertTrue(capabilities.contains("persisted_lifecycle_state_v1"))
        XCTAssertTrue(capabilities.contains("legacy_reader_fallback_v1"))
        XCTAssertTrue(capabilities.contains("service_instance_v1"))
        XCTAssertTrue(capabilities.contains("status_observation_v1"))
        XCTAssertTrue(capabilities.contains("provider_safety_telemetry_v1"))
        XCTAssertTrue(capabilities.contains("provider_safety_telemetry_v2"))
        XCTAssertTrue(capabilities.contains("referral_bootstrap_v1"))
        XCTAssertTrue(capabilities.contains("referral_status_v1"))
        XCTAssertTrue(capabilities.contains("referral_advocacy_v1"))
        XCTAssertTrue(capabilities.contains("referral_repeatable_advocacy_v1"))
        XCTAssertTrue(capabilities.contains("referral_fragment_links_v1"))
        XCTAssertTrue(capabilities.contains("model_catalog_economics_v1"))
        XCTAssertFalse(capabilities.contains("model_catalog_economics_v2"))
        XCTAssertTrue(capabilities.contains("model_catalog_economics.v1"))
        XCTAssertFalse(capabilities.contains("model_catalog_economics.v2"))
        XCTAssertTrue(capabilities.contains("models catalog-economics.v1"))
        XCTAssertFalse(capabilities.contains("models catalog-economics.v2"))
        XCTAssertTrue(capabilities.contains("model_recommendation_check_v1"))
        XCTAssertTrue(capabilities.contains("model_recommendation_apply_switch_v1"))
        XCTAssertTrue(capabilities.contains("autotune_recommend.v1"))
        XCTAssertTrue(capabilities.contains("autotune recommend installed-only check.v1"))
        XCTAssertTrue(capabilities.contains("model_recommendation_check_event.v1"))
        XCTAssertTrue(capabilities.contains("models adopt-recommendation.v1"))
        XCTAssertTrue(capabilities.contains("model_adoption_event.v1"))
        XCTAssertTrue(capabilities.contains("recommendation_apply_switch_finalize_request"))
        XCTAssertTrue(capabilities.contains("recommendation_apply_switch_finalize_result"))
        XCTAssertTrue(capabilities.contains("recommendation_apply_switch_recovery_claim_request"))
        XCTAssertTrue(capabilities.contains("recommendation_apply_switch_recovery_claim_result"))

        let observation = try XCTUnwrap(body["observation"] as? [String: Any])
        XCTAssertNotNil(observation["id"] as? String)
        XCTAssertNotNil(observation["observed_at"] as? String)
        XCTAssertEqual(observation["valid_for_ms"] as? Int, 5_000)

        let service = try XCTUnwrap(body["service_instance"] as? [String: Any])
        XCTAssertEqual(service["instance_id"] as? String, RouterHandler.serviceInstanceID)
        XCTAssertEqual(service["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(service["role"] as? String, "serve")

        let lifecycle = try XCTUnwrap(body["lifecycle"] as? [String: Any])
        XCTAssertEqual(lifecycle["record_state"] as? String, "valid")
        XCTAssertEqual(lifecycle["transition_id"] as? String, persistedLifecycle.transitionID)
        XCTAssertEqual(lifecycle["sequence"] as? UInt64, 1)
        XCTAssertEqual(lifecycle["state"] as? String, "serving_buyers")
        XCTAssertEqual(lifecycle["reason_code"] as? String, "coordinator_buyer_serving_confirmed")
        XCTAssertEqual(lifecycle["authority"] as? String, "macprovider_cli")
        XCTAssertEqual(lifecycle["operator_paused"] as? Bool, false)

        let identity = try XCTUnwrap(body["admission_identity"] as? [String: Any])
        XCTAssertEqual(identity["owner"] as? String, "macprovider_cli")
        XCTAssertEqual(identity["source"] as? String, "cli_keychain")
        XCTAssertEqual(identity["state"] as? String, "degraded_previous_key")
        XCTAssertEqual(identity["public_key_sha256"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(identity["pending_public_key_sha256"] as? String, String(repeating: "b", count: 64))
        XCTAssertEqual(identity["previous_public_key_sha256"] as? String, String(repeating: "c", count: 64))
        XCTAssertEqual(identity["previous_valid_until"] as? String, "2026-07-21T12:00:00.000Z")
        XCTAssertEqual(identity["coordinator_generation"] as? Int, 3)
        XCTAssertEqual(identity["coordinator_public_key_sha256"] as? String, String(repeating: "d", count: 64))
        XCTAssertEqual(identity["coordinator_key_role"] as? String, "previous")
        XCTAssertEqual(identity["transition_error"] as? String, "coordinator_previous_key_grace")
        XCTAssertEqual(identity["recovery_action"] as? String, "restore_current_key_or_run_recover_admission_identity")
    }

    func testStatusResponsePublishesCorrelatedBuild1LaneAStatusEvidence() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-bound-private-record")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])
        let record = try XCTUnwrap(evidence["private_record"] as? [String: Any])
        let artifact = try XCTUnwrap(evidence["artifact"] as? [String: Any])
        let runtimeCustody = try XCTUnwrap(evidence["runtime_custody"] as? [String: Any])
        let boundary = try XCTUnwrap(evidence["proof_boundary"] as? [String: Any])

        XCTAssertEqual(evidence["schema"] as? String, "build1_lane_a_status_evidence.v1")
        XCTAssertEqual(evidence["state"] as? String, "correlated")
        XCTAssertEqual(evidence["reason"] as? String, "status_matches_private_record_path_observed")
        XCTAssertEqual(evidence["record_state"] as? String, "recorded")
        XCTAssertEqual(evidence["model_hash"] as? String, fixture.binding.artifactSHA256)
        XCTAssertEqual(evidence["model_hash_algorithm"] as? String, ModelArtifactIdentity.snapshotManifestV1)
        XCTAssertEqual(evidence["model_hash_matches_private_record"] as? Bool, true)
        XCTAssertEqual(evidence["model_hash_matches_config"] as? Bool, true)
        XCTAssertEqual(evidence["model_hash_algorithm_matches_private_record"] as? Bool, true)
        XCTAssertEqual(evidence["weights_manifest_sha256"] as? String, String(repeating: "f", count: 64))
        XCTAssertEqual(evidence["weights_manifest_algorithm"] as? String, ModelArtifactIdentity.safetensorsManifestV1)
        XCTAssertEqual(evidence["weights_manifest_present"] as? Bool, true)
        XCTAssertEqual(evidence["weights_manifest_algorithm_matches_expected"] as? Bool, true)
        XCTAssertEqual(runtimeCustody["descriptor_pinned_runtime_custody"] as? Bool, false)
        XCTAssertEqual(runtimeCustody["observation_scope"] as? String, "path_observed")
        XCTAssertEqual(record["artifact_identity_digest"] as? String, fixture.binding.artifactIdentityDigest)
        XCTAssertEqual(record["receipt_sha256"] as? String, fixture.binding.receiptSHA256)
        XCTAssertEqual(record["root_identity_digest"] as? String, fixture.binding.rootIdentityDigest)
        XCTAssertEqual(record["inventory_generation"] as? Int, fixture.binding.inventoryGeneration)
        XCTAssertEqual(artifact["model_id"] as? String, Build1LaneAPrepareProfile.artifactModelID)
        XCTAssertEqual(artifact["artifact_sha256"] as? String, fixture.binding.artifactSHA256)
        XCTAssertEqual(boundary["grants_admission"] as? Bool, false)
        XCTAssertEqual(boundary["grants_settlement"] as? Bool, false)
        XCTAssertEqual(boundary["production_activation"] as? Bool, false)
        XCTAssertFalse(String(describing: evidence).contains(fixture.durableRoot.path))
    }

    func testStatusResponseDoesNotBindBuild1LaneAOnRuntimeHashMismatch() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-hash-mismatch")
        let wrongHash = String(repeating: "0", count: 64)
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: wrongHash,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])

        XCTAssertEqual(evidence["state"] as? String, "unbound")
        XCTAssertEqual(evidence["reason"] as? String, "model_hash_mismatch")
        XCTAssertEqual(evidence["model_hash"] as? String, wrongHash)
        XCTAssertEqual(evidence["model_hash_matches_private_record"] as? Bool, false)
        XCTAssertEqual(evidence["model_hash_matches_config"] as? Bool, false)
    }

    func testStatusResponseDoesNotBindBuild1LaneAOnModelHashAlgorithmMismatch() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-hash-algorithm-mismatch")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: "sha256",
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])

        XCTAssertEqual(evidence["state"] as? String, "unbound")
        XCTAssertEqual(evidence["reason"] as? String, "model_hash_algorithm_mismatch")
        XCTAssertEqual(evidence["model_hash_matches_private_record"] as? Bool, true)
        XCTAssertEqual(evidence["model_hash_algorithm_matches_private_record"] as? Bool, false)
    }

    func testStatusResponseDoesNotBindBuild1LaneAOnWeightsManifestAlgorithmMismatch() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-weights-algorithm-mismatch")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity()
        )
        let runtime = RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64),
            weightsManifestAlgorithm: "sha256"
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            runtimeSnapshot: runtime,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])

        XCTAssertEqual(evidence["state"] as? String, "unbound")
        XCTAssertEqual(evidence["reason"] as? String, "weights_manifest_algorithm_mismatch")
        XCTAssertEqual(evidence["model_hash_matches_private_record"] as? Bool, true)
        XCTAssertEqual(evidence["model_hash_algorithm_matches_private_record"] as? Bool, true)
        XCTAssertEqual(evidence["weights_manifest_present"] as? Bool, true)
        XCTAssertEqual(evidence["weights_manifest_algorithm_matches_expected"] as? Bool, false)
    }

    func testStatusResponseRevalidatesBuild1LaneARecordEachObservation() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-refreshes-private-record")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneAResolver: ProviderBuild1LaneAStatusResolver(
                durableRoot: fixture.durableRoot,
                expectedArtifactSHA256: fixture.binding.artifactSHA256,
                expectedReleaseID: fixture.binding.releaseID
            )
        )

        let first = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        XCTAssertEqual((first["build1_lane_a"] as? [String: Any])?["state"] as? String, "correlated")

        try removePublishedInventory(from: fixture.durableRoot)
        let second = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(second["build1_lane_a"] as? [String: Any])
        XCTAssertEqual(evidence["state"] as? String, "missing")
        XCTAssertEqual(evidence["record_state"] as? String, "missing")
        XCTAssertEqual(evidence["reason"] as? String, "private_record_missing")
    }

    func testStatusResponseDoesNotBindBuild1LaneAWhenExpectedArtifactDiffers() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-expected-hash-mismatch")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.catalogKey,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneAResolver: ProviderBuild1LaneAStatusResolver(
                durableRoot: fixture.durableRoot,
                expectedArtifactSHA256: String(repeating: "1", count: 64),
                expectedReleaseID: fixture.binding.releaseID
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])
        XCTAssertEqual(evidence["state"] as? String, "missing")
        XCTAssertEqual(evidence["record_state"] as? String, "missing")
        XCTAssertTrue(evidence["model_hash_matches_private_record"] is NSNull)
    }

    func testBuild1LaneAStatusReaderRequiresExpectedReleaseID() throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-release-mismatch")
        let recorder = Build1LaneAPreparationRecorder(durableRoot: fixture.durableRoot)

        let binding = try recorder.readStatusArtifactBinding(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            expectedArtifactSHA256: fixture.binding.artifactSHA256,
            expectedReleaseID: "other-release"
        )

        XCTAssertNil(binding)
    }

    func testBuild1LaneAStatusReaderValidatesAllReceiptsBeforeSelectingRelease() throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-corrupt-unselected-receipt")
        let staleRelease = try recordBuild1LaneAStatusBinding(
            durableRoot: fixture.durableRoot,
            artifactSHA256: fixture.binding.artifactSHA256,
            adoptedBytes: fixture.binding.estimatedBytes,
            releaseID: "stale-release"
        )
        try removeReceipt(from: fixture.durableRoot, artifactIdentityDigest: staleRelease.artifactIdentityDigest)
        let recorder = Build1LaneAPreparationRecorder(durableRoot: fixture.durableRoot)

        XCTAssertThrowsError(try recorder.readStatusArtifactBinding(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            expectedArtifactSHA256: fixture.binding.artifactSHA256,
            expectedReleaseID: fixture.binding.releaseID
        )) { error in
            guard case Build1LaneAPreparationRecordError.inventoryInvalid = error else {
                return XCTFail("expected inventoryInvalid, got \(error)")
            }
        }
    }

    func testStatusResponseDoesNotBindBuild1LaneAOnEffectiveModelMismatch() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-effective-model-mismatch")
        // Same hash, algorithm, and weights manifest as the correlated case,
        // but the runtime is serving a model id outside the Lane A identity set.
        let status = ProviderStatus(
            modelID: "mlx-community/Other-Model-4bit",
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])

        XCTAssertEqual(evidence["state"] as? String, "unbound")
        XCTAssertEqual(evidence["reason"] as? String, "effective_model_mismatch")
        XCTAssertEqual(evidence["effective_model"] as? String, "mlx-community/Other-Model-4bit")
        XCTAssertEqual(evidence["effective_model_matches_lane_a"] as? Bool, false)
        XCTAssertEqual(evidence["model_hash_matches_private_record"] as? Bool, true, "hash agreement alone must not correlate")
    }

    func testStatusResponseCorrelatesBuild1LaneAForArtifactAliasEffectiveModel() async throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-effective-model-alias")
        let status = ProviderStatus(
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            modelLoaded: true,
            capacity: makeCapacity(),
            modelHash: fixture.binding.artifactSHA256,
            modelHashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            weightsManifestSHA256: String(repeating: "f", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: false,
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            catalogModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: fixture.binding.modelRevision,
            artifactSHA256: fixture.binding.artifactSHA256,
            modelArtifactSHA256: fixture.binding.artifactSHA256,
            configuredReleaseID: fixture.binding.releaseID,
            configuredCatalogDigest: nil,
            build1LaneA: ProviderBuild1LaneAStatusContext(
                recordState: .recorded,
                reason: "private_record_verified",
                binding: fixture.binding
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )
        let evidence = try XCTUnwrap(body["build1_lane_a"] as? [String: Any])

        XCTAssertEqual(evidence["state"] as? String, "correlated")
        XCTAssertEqual(evidence["effective_model_matches_lane_a"] as? Bool, true)
    }

    func testBuild1LaneAStatusReaderPublishesReceiptBoundDeclaredSizeNotMeasuredBytes() throws {
        let durableRoot = try tempDir()
        let stagingRoot = try tempDir()
        let payload = "status-receipt-bound-size"
        try Data(payload.utf8).write(to: stagingRoot.appendingPathComponent("weights.bin"), options: .atomic)
        let artifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(directory: stagingRoot)
        _ = try DurableModelArtifactStore(root: durableRoot).adoptVerifiedStaging(
            staging: stagingRoot,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            sha256: artifactSHA256
        )
        let measuredBytes = Int64(payload.utf8.count)
        let declaredBytes = 4_096

        let binding = try recordBuild1LaneAStatusBinding(
            durableRoot: durableRoot,
            artifactSHA256: artifactSHA256,
            adoptedBytes: measuredBytes,
            releaseID: "test-release",
            declaredSizeBytes: declaredBytes
        )

        // The published size is the receipt tuple's signed-authority value,
        // which validatedReceipt authenticates through the receipt digest.
        // The inventory target's locally measured count is not authenticated
        // and must never be what status publishes.
        XCTAssertEqual(binding.estimatedBytes, Int64(declaredBytes))
        XCTAssertNotEqual(binding.estimatedBytes, measuredBytes)
        let inventory = try readPublishedInventory(from: durableRoot)
        let target = try XCTUnwrap(inventory.targets.first { $0.artifactIdentityDigest == binding.artifactIdentityDigest })
        XCTAssertEqual(target.estimatedBytes, measuredBytes)
    }

    func testBuild1LaneARecordReuseRefusesNoncanonicalTupleID() throws {
        let fixture = try makeBuild1LaneAStatusFixture(payload: "status-noncanonical-tuple-reuse")
        let adoptedBytes = Int64("status-noncanonical-tuple-reuse".utf8.count)
        let releaseID = "noncanonical-release"
        let legacyDigest = try writeLaneARecordWithTupleID(
            "legacy:\(Build1LaneAPrepareProfile.catalogKey):\(Build1LaneAPrepareProfile.artifactID)@\(Build1LaneAPrepareProfile.artifactRevision)",
            durableRoot: fixture.durableRoot,
            artifactSHA256: fixture.binding.artifactSHA256,
            estimatedBytes: adoptedBytes,
            releaseID: releaseID
        )
        let recorder = Build1LaneAPreparationRecorder(durableRoot: fixture.durableRoot)

        // The status reader already refuses the entry.
        XCTAssertNil(try recorder.readStatusArtifactBinding(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            expectedArtifactSHA256: fixture.binding.artifactSHA256,
            expectedReleaseID: releaseID
        ))

        // Reuse must apply the same strict predicate: the receipt re-verifies
        // at open(), but the entry describing this artifact carries a tuple id
        // that is not the canonical Lane A one, so record() neither reuses it
        // nor appends a duplicate.
        let authority = Build1LaneAArtifactAuthority(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            hashAlgorithm: ModelArtifactIdentity.snapshotManifestV1,
            hash: fixture.binding.artifactSHA256,
            sizeBytes: Int(adoptedBytes),
            feedSHA256: String(repeating: "d", count: 64),
            feedSignerKeyID: "test-signer",
            releaseID: releaseID
        )
        let session = try recorder.open()
        defer { session.close() }
        let before = try readPublishedInventory(from: fixture.durableRoot)
        XCTAssertThrowsError(try session.record(
            authority: authority,
            adoptedSHA256: authority.hash,
            adoptedBytes: adoptedBytes
        )) { error in
            guard case Build1LaneAPreparationRecordError.inventoryInvalid = error else {
                return XCTFail("expected inventoryInvalid, got \(error)")
            }
        }
        let after = try readPublishedInventory(from: fixture.durableRoot)
        XCTAssertEqual(after, before, "a refused reuse must not rewrite the inventory")
        XCTAssertEqual(after.targets.map(\.artifactIdentityDigest).sorted(), [fixture.binding.artifactIdentityDigest, legacyDigest].sorted())
    }

    /// Reads the published inventory through the store's validated path.
    private func readPublishedInventory(from durableRoot: URL) throws -> ModelPreparationInventoryRecord {
        let recorder = Build1LaneAPreparationRecorder(durableRoot: durableRoot)
        let locator = try recorder.store.bootstrapExisting().rootLocator
        let current = try XCTUnwrap(recorder.store.readRecordWithGeneration(kind: .publishedInventory, rootLocator: locator))
        return try ModelPreparationContracts.decode(
            ModelPreparationInventoryRecord.self,
            from: current.payload,
            maxBytes: ModelPreparationContracts.inventoryMaxBytes
        )
    }

    /// Appends a Lane A-shaped inventory entry whose receipt carries an
    /// arbitrary `tuple_id`, using the store's own write path so the receipt
    /// digest, artifact identity digest, and root locator all re-verify.
    private func writeLaneARecordWithTupleID(
        _ tupleID: String,
        durableRoot: URL,
        artifactSHA256: String,
        estimatedBytes: Int64,
        releaseID: String
    ) throws -> String {
        let recorder = Build1LaneAPreparationRecorder(durableRoot: durableRoot)
        let boot = try recorder.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let locator = boot.snapshot.rootLocator
        let tuple = try ModelPreparationTupleRecord(
            tupleID: tupleID,
            eventModelKey: Build1LaneAPrepareProfile.catalogKey,
            displayModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            releaseID: releaseID,
            artifactSHA256: artifactSHA256,
            estimatedBytes: estimatedBytes,
            root: locator,
            authorityOrder: 0
        )
        let receipt = try ModelPreparationPublicationReceipt(
            eventModelKey: Build1LaneAPrepareProfile.catalogKey,
            root: locator,
            tuple: tuple,
            tupleSHA256: try ModelPreparationContracts.tupleSHA256(tuple),
            publishedAt: "2027-01-15T08:00:00Z"
        )
        let receiptBytes = try ModelPreparationContracts.encode(receipt, maxBytes: ModelPreparationContracts.publicationReceiptMaxBytes)
        let receiptSHA256 = try ModelPreparationContracts.publicationReceiptSHA256(from: receiptBytes)
        let digest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            releaseID: releaseID,
            rootIdentityDigest: locator.rootIdentityDigest,
            receiptSHA256: receiptSHA256
        )
        let target = try ModelPreparationCleanupTarget(
            artifactIdentityDigest: digest,
            displayModelID: Build1LaneAPrepareProfile.artifactModelID,
            modelRevision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            releaseID: releaseID,
            modelKey: Build1LaneAPrepareProfile.catalogKey,
            eventModelKey: Build1LaneAPrepareProfile.catalogKey,
            rootIdentityDigest: locator.rootIdentityDigest,
            receiptSHA256: receiptSHA256,
            estimatedBytes: estimatedBytes,
            keepSetStatus: .protected,
            protectedReason: Build1LaneAPreparationRecorder.protectedReason,
            cleanup: try ModelPreparationAction(
                available: false,
                requiresConfirmation: false,
                transactionKind: nil,
                transactionID: nil,
                actionTimeoutSeconds: nil,
                estimatedBytes: nil,
                unavailableReason: Build1LaneAPreparationRecorder.protectedReason,
                artifactIdentityDigest: nil
            )
        )
        let objectDirectory = durableRoot
            .appendingPathComponent(ModelPreparationSecureFilesystem.namespaceLeaf, isDirectory: true)
            .appendingPathComponent(ModelPreparationSecureFilesystem.objectsLeaf, isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(
            at: objectDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let receiptURL = objectDirectory.appendingPathComponent(Build1LaneAPreparationRecorder.receiptLeaf)
        try receiptBytes.write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)

        let current = try XCTUnwrap(recorder.store.readRecordWithGeneration(kind: .publishedInventory, rootLocator: locator))
        let existing = try ModelPreparationContracts.decode(
            ModelPreparationInventoryRecord.self,
            from: current.payload,
            maxBytes: ModelPreparationContracts.inventoryMaxBytes
        )
        var targets = existing.targets
        targets.append(target)
        targets.sort { $0.artifactIdentityDigest < $1.artifactIdentityDigest }
        let inventory = try ModelPreparationInventoryRecord(root: locator, targets: targets, generatedAt: "2027-01-15T08:00:00Z")
        try recorder.store.writeRecord(
            kind: .publishedInventory,
            payload: try ModelPreparationContracts.encode(inventory, maxBytes: ModelPreparationContracts.inventoryMaxBytes),
            generation: current.generation + 1,
            rootLocator: locator,
            lockCustody: boot.lockCustody
        )
        return digest
    }

    private func makeLaneAStatusConfig() -> AppConfig {
        var config = AppConfig.defaults()
        config.model = Build1LaneAPrepareProfile.catalogKey
        config.modelCatalogKey = Build1LaneAPrepareProfile.catalogKey
        config.modelCatalogModelID = Build1LaneAPrepareProfile.artifactModelID
        config.modelCatalogRevision = Build1LaneAPrepareProfile.artifactRevision
        config.modelCatalogSHA256 = String(repeating: "a", count: 64)
        config.modelArtifactSHA256 = String(repeating: "a", count: 64)
        config.modelCatalogVersion = "test-release"
        config.coordinatorURL = "http://127.0.0.1:8787"
        return config
    }

    func testBuild1LaneAStatusResolverRequiresStagingCoordinator() {
        var config = makeLaneAStatusConfig()
        XCTAssertNotNil(ProviderBuild1LaneAStatusResolver.make(config: config))

        config.coordinatorURL = "https://coordinator.malibu.tech"
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config))

        config.coordinatorURL = "http://127.0.0.1:8787"
        config.modelCatalogVersion = nil
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config))

        config.modelCatalogVersion = "test-release"
        config.modelArtifactSHA256 = nil
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config))
    }

    func testBuild1LaneAStatusResolverRequiresExactCatalogTuple() {
        var config = makeLaneAStatusConfig()
        config.modelCatalogRevision = "0000000000000000000000000000000000000000"
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config), "revision drift must not resolve")

        config = makeLaneAStatusConfig()
        config.modelCatalogModelID = "mlx-community/Other-Model-4bit"
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config), "artifact model id drift must not resolve")

        config = makeLaneAStatusConfig()
        config.modelCatalogKey = nil
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config), "model alias alone must not resolve")

        config = makeLaneAStatusConfig()
        config.modelCatalogSHA256 = String(repeating: "b", count: 64)
        XCTAssertNil(ProviderBuild1LaneAStatusResolver.make(config: config), "catalog/artifact digest disagreement must not resolve")

        config = makeLaneAStatusConfig()
        config.modelCatalogSHA256 = nil
        XCTAssertNotNil(ProviderBuild1LaneAStatusResolver.make(config: config))
    }

    func testStatusResponsePublishesFreshCompleteSafetyTelemetry() async throws {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .serious))
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: makeCapacity(maxConcurrency: 1),
            thermalGate: gate,
            memoryPressureProvider: FixedMemoryPressureProvider(value: .warning)
        )
        await status.setCoordinatorSession(connected: true, assignedID: "session-a", tier: "pinned")
        let snapshot = await status.snapshot()
        let body = RouterHandler.statusResponse(snapshot, providerID: "provider-a", coordinatorURL: nil)
        let observation = try XCTUnwrap(body["observation"] as? [String: Any])
        let telemetry = try XCTUnwrap(body["safety_telemetry"] as? [String: Any])

        XCTAssertEqual(telemetry["schema_version"] as? Int, 1)
        XCTAssertEqual(telemetry["provider_id"] as? String, "provider-a")
        XCTAssertEqual(telemetry["model_id"] as? String, "model-a")
        XCTAssertEqual(telemetry["model_loaded"] as? Bool, true)
        XCTAssertEqual(telemetry["runtime_state"] as? String, "busy")
        XCTAssertEqual(telemetry["hardware_tier"] as? String, snapshot.capacity.ramTier)
        XCTAssertEqual(telemetry["requests_in_flight"] as? Int, 0)
        XCTAssertEqual(telemetry["requests_queued"] as? Int, 0)
        XCTAssertEqual(telemetry["memory_rss_mb"] as? Int, snapshot.memoryRSSMB)
        XCTAssertEqual(telemetry["memory_capacity_mb"] as? Int, snapshot.capacity.ramGB * 1024)
        XCTAssertEqual(telemetry["memory_pressure"] as? String, "warning")
        XCTAssertEqual(telemetry["thermal_state"] as? String, "serious")
        XCTAssertEqual(telemetry["thermally_throttled"] as? Bool, true)
        XCTAssertEqual(telemetry["restart_count"] as? Int, snapshot.restartCount)
        XCTAssertEqual(telemetry["uptime_s"] as? Int, snapshot.uptimeSeconds)
        XCTAssertEqual(telemetry["coordinator_connected"] as? Bool, true)
        XCTAssertEqual(telemetry["observation_id"] as? String, observation["id"] as? String)
        XCTAssertEqual(telemetry["observed_at"] as? String, observation["observed_at"] as? String)
        XCTAssertEqual(telemetry["valid_for_ms"] as? Int, 5_000)
    }

    func testStatusResponsePublishesSessionAndBuildBoundV2SafetyTelemetry() async throws {
        let modelHash = String(repeating: "a", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: makeCapacity(maxConcurrency: 1),
            modelHash: modelHash,
            workloadTelemetryProvider: FixedWorkloadTelemetryProvider(value: ProviderWorkloadTelemetry(
                cpuUtilizationPercent: 12.5,
                gpuUtilizationPercent: 18.0,
                gpuUtilizationScope: "host",
                powerSource: .external
            ))
        )
        await status.setCoordinatorSession(connected: true, assignedID: "session-a", tier: "pinned")
        let snapshot = await status.snapshot()
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: "Augustas11/macprovider:v1.8.33@0123456789abcdef0123456789abcdef01234567",
            envelopeSHA256: String(repeating: "b", count: 64),
            version: "1.8.33",
            catalogReleaseID: "acceptance-2026-07-14",
            catalogPolicyVersion: "catalog-policy-v1",
            maintenanceLeaseSeconds: 1_200,
            readinessTimeoutSeconds: 1_200
        )
        let body = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: nil,
            compatibilitySetManifest: manifest
        )
        let telemetry = try XCTUnwrap(body["safety_telemetry"] as? [String: Any])
        XCTAssertEqual(telemetry["schema_version"] as? Int, 2)
        XCTAssertEqual(telemetry["coordinator_session_id"] as? String, "session-a")
        XCTAssertEqual(telemetry["cpu_utilization_pct"] as? Double, 12.5)
        XCTAssertEqual(telemetry["gpu_utilization_pct"] as? Double, 18.0)
        XCTAssertEqual(telemetry["gpu_utilization_scope"] as? String, "host")
        XCTAssertEqual(telemetry["power_source"] as? String, "external")
        XCTAssertEqual(telemetry["binary_version"] as? String, CoordinatorClient.binaryVersion)
        XCTAssertEqual(telemetry["compatibility_set_id"] as? String, manifest.compatibilitySetID)
        XCTAssertEqual(telemetry["model_hash"] as? String, modelHash)
    }

    func testV2SafetyTelemetryKeepsHostGPUScopeWhenSampleIsTemporarilyUnavailable() async {
        let modelHash = String(repeating: "a", count: 64)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: makeCapacity(maxConcurrency: 1),
            modelHash: modelHash,
            workloadTelemetryProvider: FixedWorkloadTelemetryProvider(value: ProviderWorkloadTelemetry(
                cpuUtilizationPercent: 12.5,
                gpuUtilizationPercent: nil,
                gpuUtilizationScope: "host",
                powerSource: .external
            ))
        )
        await status.setCoordinatorSession(connected: true, assignedID: "session-a", tier: "pinned")
        let snapshot = await status.snapshot()
        let telemetry = snapshot.safetyTelemetry(
            providerID: "provider-a",
            modelID: "model-a",
            binaryVersion: CoordinatorClient.binaryVersion,
            compatibilitySetID: "set-a",
            modelHash: modelHash,
            observationID: "observation-a",
            observedAt: "2026-07-14T12:00:00Z",
            validForMS: 90_000
        )
        XCTAssertTrue(telemetry["gpu_utilization_pct"] is NSNull)
        XCTAssertEqual(telemetry["gpu_utilization_scope"] as? String, "host")
    }

    func testQueueDepthCountsAdmittedRequestsBeyondInferenceCapacity() async {
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 1))
        _ = await status.beginRequest(requestID: "running")
        _ = await status.beginRequest(requestID: "waiting")
        let queued = await status.snapshot()
        XCTAssertEqual(queued.requestsInFlight, 2)
        XCTAssertEqual(queued.requestsQueued, 1)
    }

    func testStatusResponsePublishesCompatibilitySetAndRedactedLifecycleLease() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snapshot = await status.snapshot()
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: "Augustas11/macprovider:v1.9.0@0123456789abcdef0123456789abcdef01234567",
            envelopeSHA256: String(repeating: "a", count: 64),
            version: "1.9.0",
            catalogReleaseID: "published-2026-07-14",
            catalogPolicyVersion: "catalog-policy-v1",
            maintenanceLeaseSeconds: 1_200,
            readinessTimeoutSeconds: 1_200
        )
        let lease = ProviderLifecycleLeaseRecord(
            version: 1,
            leaseID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            operationID: "autoupdate:ffffffff-1111-4222-8333-444444444444",
            kind: .maintenance,
            owner: ProviderLifecycleLeaseOwner(
                pid: 4321,
                processStartMicroseconds: 10,
                bootSession: "boot-a"
            ),
            issuedWallMilliseconds: 100,
            expiresWallMilliseconds: 1_200_100,
            issuedMonotonicNanoseconds: 1_000,
            expiresMonotonicNanoseconds: 1_200_001_000
        )

        let body = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: nil,
            lifecycleLeaseInspection: .valid(lease),
            compatibilitySetManifest: manifest
        )

        XCTAssertEqual(body["compatibility_set_id"] as? String, manifest.compatibilitySetID)
        XCTAssertEqual(body["compatibility_set_sha256"] as? String, manifest.envelopeSHA256)
        let lifecycle = try XCTUnwrap(body["lifecycle_lease"] as? [String: Any])
        XCTAssertEqual(lifecycle["state"] as? String, "active")
        XCTAssertEqual(lifecycle["kind"] as? String, "maintenance")
        XCTAssertEqual(lifecycle["operation_id"] as? String, lease.operationID)
        XCTAssertEqual(lifecycle["owner_pid"] as? Int, 4321)
        XCTAssertEqual(lifecycle["expires_wall_ms"] as? Int64, 1_200_100)
        XCTAssertNil(lifecycle["lease_id"])
        XCTAssertNil(lifecycle["process_start_us"])
        XCTAssertNil(lifecycle["boot_session"])
    }

    func testStatusObservationsAreUniqueWhileServiceInstanceRemainsStable() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snapshot = await status.snapshot()
        let first = RouterHandler.statusResponse(snapshot, providerID: "provider-a", coordinatorURL: nil)
        let second = RouterHandler.statusResponse(snapshot, providerID: "provider-a", coordinatorURL: nil)

        let firstObservation = try XCTUnwrap(first["observation"] as? [String: Any])
        let secondObservation = try XCTUnwrap(second["observation"] as? [String: Any])
        XCTAssertNotEqual(firstObservation["id"] as? String, secondObservation["id"] as? String)

        let firstService = try XCTUnwrap(first["service_instance"] as? [String: Any])
        let secondService = try XCTUnwrap(second["service_instance"] as? [String: Any])
        XCTAssertEqual(firstService["instance_id"] as? String, secondService["instance_id"] as? String)
        XCTAssertEqual(firstService["started_at"] as? String, secondService["started_at"] as? String)
    }

    func testStatusFailsClosedWhenPersistedLifecycleIsMissingOrInvalid() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snapshot = await status.snapshot()

        let missing = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: nil,
            lifecycleStateInspection: .missing
        )
        let missingLifecycle = try XCTUnwrap(missing["lifecycle"] as? [String: Any])
        XCTAssertEqual(missingLifecycle["record_state"] as? String, "missing")
        XCTAssertEqual(missingLifecycle["state"] as? String, "failed")
        XCTAssertEqual(missingLifecycle["reason_code"] as? String, "lifecycle_state_missing")
        XCTAssertTrue(missingLifecycle["transition_id"] is NSNull)

        let invalid = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: nil,
            lifecycleStateInspection: .invalid(reason: "unsafe storage")
        )
        let invalidLifecycle = try XCTUnwrap(invalid["lifecycle"] as? [String: Any])
        XCTAssertEqual(invalidLifecycle["record_state"] as? String, "invalid")
        XCTAssertEqual(invalidLifecycle["state"] as? String, "failed")
        XCTAssertEqual(invalidLifecycle["reason_code"] as? String, "lifecycle_state_invalid")
        XCTAssertEqual(invalidLifecycle["invalid_reason"] as? String, "unsafe storage")
    }

    func testLifecycleTransitionIdentifiesCapacityEdges() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 1))
        let initial = await status.snapshot()

        let startedAt = await status.beginRequest(requestID: "request-1")
        let busy = await status.snapshot()
        XCTAssertEqual(busy.status, .busy)
        XCTAssertEqual(busy.transitionReason, "request_capacity_full")
        XCTAssertNotEqual(busy.transitionID, initial.transitionID)

        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "request-1")
        let ready = await status.snapshot()
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.transitionReason, "request_capacity_available")
        XCTAssertNotEqual(ready.transitionID, busy.transitionID)
    }

    func testRequestCapacityTransitionsNotifyHandler() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 1))
        let recorder = RequestCapacityReasonRecorder()
        await status.setRequestCapacityChangeHandler { transition in
            recorder.record(transition.reason)
        }

        let startedAt = await status.beginRequest(requestID: "request-1")
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "request-1")
        await status.setRequestCapacityChangeHandler(nil)

        XCTAssertEqual(recorder.reasons, ["request_capacity_full", "request_capacity_available"])
    }

    func testRequestCapacityTransitionsNotifyEverySlotDelta() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 4))
        let recorder = RequestCapacitySnapshotRecorder()
        await status.setRequestCapacityChangeHandler { transition in
            recorder.record(transition)
        }

        let first = await status.beginRequest(requestID: "request-1")
        let second = await status.beginRequest(requestID: "request-2")
        let third = await status.beginRequest(requestID: "request-3")
        let fourth = await status.beginRequest(requestID: "request-4")
        await status.finishRequest(startedAt: fourth, completion: nil, failed: false, requestID: "request-4")
        await status.finishRequest(startedAt: third, completion: nil, failed: false, requestID: "request-3")
        await status.finishRequest(startedAt: second, completion: nil, failed: false, requestID: "request-2")
        await status.finishRequest(startedAt: first, completion: nil, failed: false, requestID: "request-1")
        await status.setRequestCapacityChangeHandler(nil)

        XCTAssertEqual(recorder.slotsFree, [3, 2, 1, 0, 1, 2, 3, 4])
        XCTAssertEqual(recorder.states, [.ready, .ready, .ready, .busy, .ready, .ready, .ready, .ready])
        XCTAssertEqual(recorder.reasons, [
            "request_capacity_available",
            "request_capacity_available",
            "request_capacity_available",
            "request_capacity_full",
            "request_capacity_available",
            "request_capacity_available",
            "request_capacity_available",
            "request_capacity_available",
        ])
    }

    func testRequestCapacityTransitionsUseEffectiveThermalSlots() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .serious))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 4), thermalGate: gate)
        _ = await status.snapshot()
        let recorder = RequestCapacitySnapshotRecorder()
        await status.setRequestCapacityChangeHandler { transition in
            recorder.record(transition)
        }

        let startedAt = await status.beginRequest(requestID: "request-1")
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "request-1")
        await status.setRequestCapacityChangeHandler(nil)

        XCTAssertEqual(recorder.slotsFree, [0])
        XCTAssertEqual(recorder.states, [.busy])
        XCTAssertEqual(recorder.reasons, ["thermal_throttled"])
    }

    func testRequestCapacityTransitionsEmitAfterPublishedThermalZeroRecovers() async {
        let thermalProvider = MutableThermalProvider(initial: .serious)
        let gate = ThermalGate(stateProvider: thermalProvider)
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 4), thermalGate: gate)
        _ = await status.snapshot()
        let recorder = RequestCapacitySnapshotRecorder()
        await status.setRequestCapacityChangeHandler { transition in
            recorder.record(transition)
        }

        let throttledStartedAt = await status.beginRequest(requestID: "request-throttled")
        await status.finishRequest(startedAt: throttledStartedAt, completion: nil, failed: false, requestID: "request-throttled")
        await gate.inject(state: .nominal)
        let recoveredStartedAt = await status.beginRequest(requestID: "request-recovered")
        await status.finishRequest(startedAt: recoveredStartedAt, completion: nil, failed: false, requestID: "request-recovered")
        await status.setRequestCapacityChangeHandler(nil)

        XCTAssertEqual(recorder.slotsFree, [0, 3, 4])
        XCTAssertEqual(recorder.states, [.busy, .ready, .ready])
        XCTAssertEqual(recorder.reasons, [
            "thermal_throttled",
            "request_capacity_available",
            "request_capacity_available",
        ])
    }

    func testRequestCapacityTransitionsNotifySlotsTotalDelta() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 2))
        let recorder = RequestCapacitySnapshotRecorder()
        await status.setRequestCapacityChangeHandler { transition in
            recorder.record(transition)
        }

        let startedAt = await status.beginRequest(requestID: "request-1")
        await status.completeTargetSwap(modelID: "m", modelHash: nil, maxConcurrency: 4)
        await status.finishRequest(startedAt: startedAt, completion: nil, failed: false, requestID: "request-1")
        await status.setRequestCapacityChangeHandler(nil)

        XCTAssertEqual(Array(recorder.slotsTotal.prefix(2)), [2, 4])
        XCTAssertEqual(Array(recorder.slotsFree.prefix(2)), [1, 3])
    }

    func testSpecDecodeStatusFieldsAreDisabledWithoutDraftConfig() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let snap = await status.snapshot()
        let fields = RouterHandler.specDecodeTelemetryFields(snap)

        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertNil(snap.specDecodeDraftModelID)
        XCTAssertNil(snap.specDecodeNumDraftTokens)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
        XCTAssertEqual(fields["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(fields["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(fields["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertTrue(fields["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusFieldsExposeEnabledNoWindowShape() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()
        let body = RouterHandler.statusResponse(snap, providerID: "provider-a", coordinatorURL: nil)

        XCTAssertTrue(snap.specDecodeEnabled)
        XCTAssertEqual(snap.specDecodeDraftModelID, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertEqual(snap.specDecodeNumDraftTokens, 3)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
        XCTAssertEqual(body["spec_decode_enabled"] as? Bool, true)
        XCTAssertEqual(body["spec_decode_draft_model_id"] as? String, "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertEqual(body["spec_decode_num_draft_tokens"] as? Int, 3)
        XCTAssertTrue(body["spec_decode_acceptance_rate"] is NSNull)
    }

    func testStatusResponseUsesRuntimeModelDuringProviderStatusLag() async {
        let status = ProviderStatus(modelID: "old-model", modelLoaded: false, capacity: makeCapacity())
        let snap = await status.snapshot()
        let runtimeSnapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "new-model", modelHash: "new-hash")

        let body = RouterHandler.statusResponse(
            snap,
            providerID: "provider-a",
            coordinatorURL: nil,
            runtimeSnapshot: runtimeSnapshot
        )

        XCTAssertEqual(body["model"] as? String, "new-model")
        XCTAssertEqual(body["model_loaded"] as? Bool, true)
    }

    func testStatusResponsePublishesInactiveContinuousBatchingBlockWithoutRuntimeSnapshot() async throws {
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: makeCapacity())
        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil
        )

        let continuousBatching = try XCTUnwrap(body["continuous_batching"] as? [String: Any])
        XCTAssertEqual(continuousBatching["mode"] as? String, "off")
        XCTAssertEqual(continuousBatching["active"] as? Bool, false)
        XCTAssertTrue(continuousBatching["unsupported_reason"] is NSNull)
        XCTAssertTrue(continuousBatching["paged_kv_decision"] is NSNull)
        XCTAssertTrue(continuousBatching["cache_class"] is NSNull)

        let scheduler = try XCTUnwrap(continuousBatching["scheduler"] as? [String: Any])
        XCTAssertEqual(scheduler["active_decode_rows"] as? Int, 0)
        XCTAssertEqual(scheduler["waiting_count"] as? Int, 0)
        XCTAssertEqual(scheduler["max_observed_batch_depth"] as? Int, 0)
        XCTAssertEqual(scheduler["slots_total"] as? Int, 0)
        XCTAssertEqual(scheduler["slots_free"] as? Int, 0)
    }

    func testStatusResponsePublishesContinuousBatchingRuntimeSnapshot() async throws {
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: makeCapacity())
        let runtimeSnapshot = RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "model-a",
            modelHash: "hash-a",
            continuousBatching: RuntimeContinuousBatchingSnapshot(
                mode: .canary,
                active: true,
                unsupportedReason: nil,
                pagedKVDecision: "attached",
                cacheClass: "mixed",
                scheduler: RuntimeContinuousBatchingSchedulerSnapshot(
                    activeDecodeRows: 3,
                    waitingCount: 2,
                    maxObservedBatchDepth: 4,
                    slotsTotal: 8,
                    slotsFree: 5
                )
            )
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            runtimeSnapshot: runtimeSnapshot
        )

        let continuousBatching = try XCTUnwrap(body["continuous_batching"] as? [String: Any])
        XCTAssertEqual(continuousBatching["mode"] as? String, "canary")
        XCTAssertEqual(continuousBatching["active"] as? Bool, true)
        XCTAssertTrue(continuousBatching["unsupported_reason"] is NSNull)
        XCTAssertEqual(continuousBatching["paged_kv_decision"] as? String, "attached")
        XCTAssertEqual(continuousBatching["cache_class"] as? String, "mixed")

        let scheduler = try XCTUnwrap(continuousBatching["scheduler"] as? [String: Any])
        XCTAssertEqual(scheduler["active_decode_rows"] as? Int, 3)
        XCTAssertEqual(scheduler["waiting_count"] as? Int, 2)
        XCTAssertEqual(scheduler["max_observed_batch_depth"] as? Int, 4)
        XCTAssertEqual(scheduler["slots_total"] as? Int, 8)
        XCTAssertEqual(scheduler["slots_free"] as? Int, 5)
    }

    func testStatusSeparatesLiveCatalogTrustFromBuyerServing() async {
        let status = ProviderStatus(modelID: "model-key", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true, assignedID: "session-a")
        let trust = ServeCommand.CatalogRuntimeTrust(
            state: "live_verified",
            releaseID: "release-a",
            digest: String(repeating: "a", count: 64),
            signerKeyID: "streamvc-autotune-static-v5",
            source: "coordinator",
            policyVersion: "autotune-policy-v1",
            rowIdentity: String(repeating: "e", count: 64)
        )
        let context = ProviderCatalogStatusContext(
            trust: trust,
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: String(repeating: "b", count: 40),
            artifactSHA256: String(repeating: "c", count: 64),
            configuredReleaseID: "release-a",
            configuredCatalogDigest: String(repeating: "a", count: 64)
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: context,
            coordinatorBuyerServing: true
        )
        let catalog = body["catalog"] as? [String: Any]

        XCTAssertEqual(body["model"] as? String, "model-key")
        XCTAssertEqual(body["network_state"] as? String, "buyer_serving")
        XCTAssertEqual(body["buyer_serving_authority"] as? String, "coordinator")
        XCTAssertEqual(catalog?["state"] as? String, "live_verified")
        XCTAssertEqual(catalog?["catalog_key"] as? String, "model-key")
        XCTAssertEqual(catalog?["model_id"] as? String, "org/model")
        XCTAssertEqual(catalog?["signer_key_id"] as? String, "streamvc-autotune-static-v5")
        XCTAssertEqual(catalog?["policy_version"] as? String, "autotune-policy-v1")
        XCTAssertEqual(catalog?["row_identity"] as? String, String(repeating: "e", count: 64))
    }

    /// Issue #1616 — local status must reproduce the coordinator's own reason
    /// for withholding buyer routing. The reason existed on the wire and was
    /// discarded by the CLI, so operators had to read coordinator logs to
    /// learn why a provider said `not_buyer_serving`.
    func testStatusReportsCoordinatorBuyerServingHoldOnlyWhenNotServing() async {
        let status = ProviderStatus(modelID: "model-key", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true, assignedID: "session-a")
        let context = ProviderCatalogStatusContext(
            trust: ServeCommand.CatalogRuntimeTrust(
                state: "live_verified",
                releaseID: "release-a",
                digest: String(repeating: "a", count: 64),
                signerKeyID: "streamvc-autotune-static-v5",
                source: "coordinator",
                policyVersion: "autotune-policy-v1",
                rowIdentity: String(repeating: "e", count: 64)
            ),
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: String(repeating: "b", count: 40),
            artifactSHA256: String(repeating: "c", count: 64),
            configuredReleaseID: "release-a",
            configuredCatalogDigest: String(repeating: "a", count: 64)
        )
        let snapshot = await status.snapshot()

        let held = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: context,
            coordinatorBuyerServing: false,
            coordinatorBuyerServingHold: .modelAdmissionPending
        )
        XCTAssertEqual(held["network_state"] as? String, "not_buyer_serving")
        XCTAssertEqual(held["buyer_serving_hold"] as? String, "model_admission_pending")

        let catalogHeld = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: context,
            coordinatorBuyerServing: false,
            coordinatorBuyerServingHold: .catalogMaterialMissing
        )
        XCTAssertEqual(catalogHeld["network_state"] as? String, "not_buyer_serving")
        XCTAssertEqual(catalogHeld["buyer_serving_hold"] as? String, "catalog_material_missing")

        // An authoritative not-serving with no coordinator reason is explicitly
        // null, never a locally invented one.
        let unexplained = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: context,
            coordinatorBuyerServing: false
        )
        XCTAssertEqual(unexplained["network_state"] as? String, "not_buyer_serving")
        XCTAssertTrue(unexplained["buyer_serving_hold"] is NSNull)

        // A serving provider has no hold to report.
        let serving = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: context,
            coordinatorBuyerServing: true
        )
        XCTAssertEqual(serving["network_state"] as? String, "buyer_serving")
        XCTAssertTrue(serving["buyer_serving_hold"] is NSNull)
    }

    /// R2 architecture MEDIUM — `network_state` is computed from local
    /// readiness and catalog trust, not from the coordinator verdict alone. A
    /// donor-mode or not-yet-verified provider is not `not_buyer_serving`, so
    /// the coordinator's hold is not the reason and SPEC-001 requires null.
    func testBuyerServingHoldIsSuppressedWhenNetworkStateIsNotNotBuyerServing() async {
        let status = ProviderStatus(modelID: "model-key", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true, assignedID: "session-a")
        let snapshot = await status.snapshot()
        let donor = ProviderCatalogStatusContext(
            trust: nil,
            donorMode: true,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: String(repeating: "b", count: 40),
            artifactSHA256: String(repeating: "c", count: 64),
            configuredReleaseID: nil,
            configuredCatalogDigest: nil
        )
        let body = RouterHandler.statusResponse(
            snapshot,
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/provider/ws",
            catalogStatus: donor,
            coordinatorBuyerServing: false,
            coordinatorBuyerServingHold: .modelAdmissionPending
        )
        XCTAssertEqual(body["network_state"] as? String, "local_donor")
        XCTAssertTrue(body["buyer_serving_hold"] is NSNull)
    }

    /// R2 code-review MEDIUM — pins the projection the status handler uses, so
    /// a regression that discards the coordinator's reason cannot pass. The
    /// signature itself is the stronger guard: it does not accept the `Bool?`
    /// that `CoordinatorReadinessClient.fetch` returns.
    func testReportableBuyerServingHoldOnlyForAuthoritativeNotServing() {
        XCTAssertEqual(
            RouterHandler.reportableBuyerServingHold(
                readiness: .notServing(hold: .modelAdmissionPending),
                resolvedBuyerServing: false
            ),
            .modelAdmissionPending
        )
        XCTAssertNil(RouterHandler.reportableBuyerServingHold(
            readiness: .notServing(hold: nil),
            resolvedBuyerServing: false
        ))
        // Held true through an indeterminate probe: the coordinator said
        // nothing this round, so there is no live hold to report.
        XCTAssertNil(RouterHandler.reportableBuyerServingHold(
            readiness: .notServing(hold: .modelAdmissionPending),
            resolvedBuyerServing: true
        ))
        XCTAssertNil(RouterHandler.reportableBuyerServingHold(
            readiness: .indeterminate,
            resolvedBuyerServing: nil
        ))
        XCTAssertNil(RouterHandler.reportableBuyerServingHold(
            readiness: .confirmed,
            resolvedBuyerServing: true
        ))
    }

    func testBuyerServingHoldCapabilityIsAdvertised() {
        XCTAssertTrue(RouterHandler.localStatusCapabilities.contains("buyer_serving_hold_v1"))
    }

    func testStatusDoesNotCallOfflineFallbackBuyerServing() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true)
        let context = ProviderCatalogStatusContext(
            trust: ServeCommand.CatalogRuntimeTrust(
                state: "safe_offline_fallback",
                releaseID: "baked-release",
                digest: String(repeating: "d", count: 64),
                signerKeyID: nil,
                source: "baked"
            ),
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: nil,
            artifactSHA256: nil,
            configuredReleaseID: nil,
            configuredCatalogDigest: nil
        )

        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: nil,
            catalogStatus: context
        )

        XCTAssertEqual(body["network_state"] as? String, "safe_offline_fallback")
    }

    func testStatusCallsFallbackBuyerServingAfterCoordinatorCompatibilityAck() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true)
        await status.setCatalogCompatibilityConfirmed(true)
        let context = ProviderCatalogStatusContext(
            trust: ServeCommand.CatalogRuntimeTrust(
                state: "safe_offline_fallback",
                releaseID: "recognized-previous",
                digest: String(repeating: "d", count: 64),
                signerKeyID: "streamvc-autotune-static-v4",
                source: "baked"
            ),
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: nil,
            artifactSHA256: nil,
            configuredReleaseID: nil,
            configuredCatalogDigest: nil
        )
        let body = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/ws/provider",
            catalogStatus: context,
            coordinatorBuyerServing: true
        )
        XCTAssertEqual(body["network_state"] as? String, "buyer_serving")
        XCTAssertEqual((body["catalog"] as? [String: Any])?["state"] as? String, "safe_offline_fallback")
    }

    func testStatusNeverInfersBuyerServingWhenCoordinatorVerdictIsUnknownOrFalse() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true)
        let context = ProviderCatalogStatusContext(
            trust: ServeCommand.CatalogRuntimeTrust(
                state: "live_verified",
                releaseID: "release-a",
                digest: String(repeating: "a", count: 64),
                signerKeyID: "signer-v5",
                source: "coordinator"
            ),
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: nil,
            artifactSHA256: nil,
            configuredReleaseID: nil,
            configuredCatalogDigest: nil
        )

        let unknown = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/ws/provider",
            catalogStatus: context
        )
        let rejected = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/ws/provider",
            catalogStatus: context,
            coordinatorBuyerServing: false
        )

        XCTAssertEqual(unknown["network_state"] as? String, "buyer_serving_unknown")
        XCTAssertEqual(unknown["buyer_serving_authority"] as? String, "unknown")
        XCTAssertEqual(rejected["network_state"] as? String, "not_buyer_serving")
        XCTAssertEqual(rejected["buyer_serving_authority"] as? String, "coordinator")
    }

    func testCoordinatorBuyerServingHoldKeepsLastTrueOnIndeterminate() {
        XCTAssertEqual(
            CoordinatorBuyerServingHold.resolve(latest: true, lastConfirmedTrue: false).verdict,
            true
        )
        XCTAssertEqual(
            CoordinatorBuyerServingHold.resolve(latest: nil, lastConfirmedTrue: true).verdict,
            true
        )
        XCTAssertNil(CoordinatorBuyerServingHold.resolve(latest: nil, lastConfirmedTrue: false).verdict)
        XCTAssertEqual(
            CoordinatorBuyerServingHold.resolve(latest: false, lastConfirmedTrue: true).verdict,
            false
        )
        XCTAssertNil(CoordinatorBuyerServingHold.resolve(latest: nil, lastConfirmedTrue: false).verdict)
        let afterFalse = CoordinatorBuyerServingHold.resolve(latest: false, lastConfirmedTrue: true)
        XCTAssertEqual(afterFalse.lastConfirmedTrue, false)
        XCTAssertNil(CoordinatorBuyerServingHold.resolve(latest: nil, lastConfirmedTrue: afterFalse.lastConfirmedTrue).verdict)
    }

    func testProviderStatusAppliesLastConfirmedBuyerServingOnUnknown() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let confirmedTrue = await status.applyCoordinatorBuyerServing(true)
        let heldTrue = await status.applyCoordinatorBuyerServing(nil)
        let authoritativeFalse = await status.applyCoordinatorBuyerServing(false)
        let unknownAfterFalse = await status.applyCoordinatorBuyerServing(nil)
        XCTAssertEqual(confirmedTrue, true)
        XCTAssertEqual(heldTrue, true)
        XCTAssertEqual(authoritativeFalse, false)
        XCTAssertNil(unknownAfterFalse)
    }

    func testCoordinatorBuyerServingHoldDoesNotCrossAssignedSessions() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true, assignedID: "session-a")
        let sessionATrue = await status.applyCoordinatorBuyerServing(true)
        let sessionAHeld = await status.applyCoordinatorBuyerServing(nil)
        await status.setCoordinatorSession(connected: true, assignedID: "session-b")
        let sessionBUnknown = await status.applyCoordinatorBuyerServing(nil)
        let sessionBTrue = await status.applyCoordinatorBuyerServing(true)
        let sessionBHeld = await status.applyCoordinatorBuyerServing(nil)
        XCTAssertEqual(sessionATrue, true)
        XCTAssertEqual(sessionAHeld, true)
        XCTAssertNil(sessionBUnknown)
        XCTAssertEqual(sessionBTrue, true)
        XCTAssertEqual(sessionBHeld, true)
    }

    func testCoordinatorBuyerServingHoldIgnoresStaleInFlightAssignedSession() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: true, assignedID: "session-a")
        let sessionATrue = await status.applyCoordinatorBuyerServing(true, forAssignedID: "session-a")
        await status.setCoordinatorSession(connected: true, assignedID: "session-b")
        let staleATrue = await status.applyCoordinatorBuyerServing(true, forAssignedID: "session-a")
        let sessionBUnknown = await status.applyCoordinatorBuyerServing(nil, forAssignedID: "session-b")
        XCTAssertEqual(sessionATrue, true)
        XCTAssertNil(staleATrue)
        XCTAssertNil(sessionBUnknown)
    }

    func testStatusKeepsPoolVerdictWhenCoordinatorSocketDrops() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.setCoordinatorSession(connected: false, assignedID: "session-a")
        let context = ProviderCatalogStatusContext(
            trust: ServeCommand.CatalogRuntimeTrust(
                state: "live_verified",
                releaseID: "release-a",
                digest: String(repeating: "a", count: 64),
                signerKeyID: "signer-v5",
                source: "coordinator"
            ),
            donorMode: false,
            catalogKey: "model-key",
            catalogModelID: "org/model",
            modelRevision: nil,
            artifactSHA256: nil,
            configuredReleaseID: nil,
            configuredCatalogDigest: nil
        )

        let serving = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/ws/provider",
            catalogStatus: context,
            coordinatorBuyerServing: true
        )
        let unknown = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.malibu.tech/ws/provider",
            catalogStatus: context
        )

        XCTAssertEqual(serving["network_state"] as? String, "buyer_serving")
        XCTAssertEqual((serving["catalog"] as? [String: Any])?["state"] as? String, "live_verified")
        XCTAssertEqual(unknown["network_state"] as? String, "buyer_serving_unknown")
        XCTAssertNotEqual(unknown["network_state"] as? String, "live_verified")
    }

    func testCoordinatorReadinessURLUsesPublicReadinessEndpoint() throws {
        let url = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.malibu.tech/v1/ws/provider?ignored=true",
            providerID: "provider a",
            assignedID: "session-a"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "coordinator.malibu.tech")
        XCTAssertEqual(components.path, "/v1/pool/check")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? []), [
            "provider_id": "provider a",
            "assigned_id": "session-a",
            "details": "readiness",
        ])
        XCTAssertNil(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "http://coordinator.malibu.tech/v1/ws/provider",
            providerID: "provider-a",
            assignedID: "session-a"
        ))
    }

    func testCoordinatorReadinessVerdictRejectsRedirectsAndNonAdmittedServingClaims() throws {
        let requestURL = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.malibu.tech/v1/ws/provider",
            providerID: "provider-a",
            assignedID: "session-a"
        ))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let redirected = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://attacker.invalid/v1/pool/check")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        func body(mode: String, serving: Bool = true) -> Data {
            Data("""
            {"provider_id":"provider-a","assigned_id":"session-a","buyer_serving":\(serving),"catalog_admission_mode":"\(mode)","catalog_evidence_source":"provider_reported"}
            """.utf8)
        }

        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: body(mode: "current"), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ), true)
        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: body(mode: "previous"), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ), true)
        XCTAssertNil(CoordinatorReadinessClient.verdict(
            data: body(mode: "legacy"), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ))
        XCTAssertNil(CoordinatorReadinessClient.verdict(
            data: body(mode: "current"), response: redirected, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ))
        let staleAssignedSession = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))
        XCTAssertNil(CoordinatorReadinessClient.verdict(
            data: Data(), response: staleAssignedSession, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ))
        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: body(mode: "legacy", serving: false), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ), false)
    }

    func testCoordinatorReadinessHoldIsCarriedOnlyOnAuthoritativeNotServing() throws {
        let requestURL = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.malibu.tech/v1/ws/provider",
            providerID: "provider-a",
            assignedID: "session-a"
        ))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        func body(serving: Bool, hold: String?) throws -> Data {
            var object: [String: Any] = [
                "provider_id": "provider-a",
                "assigned_id": "session-a",
                "buyer_serving": serving,
                "catalog_admission_mode": "current",
                "catalog_evidence_source": "provider_reported",
            ]
            if let hold { object["buyer_serving_hold"] = hold }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func readiness(_ data: Data) -> CoordinatorReadinessClient.Readiness {
            CoordinatorReadinessClient.readiness(
                data: data, response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
            )
        }

        // SPEC-047-R003(iv): the coordinator's admission hold rides on an
        // authoritative not-serving verdict.
        XCTAssertEqual(readiness(try body(serving: false, hold: "model_admission_pending")), .notServing(hold: .modelAdmissionPending))
        // SPEC-001 v1.9.21: missing network catalog material is a closed hold too.
        XCTAssertEqual(readiness(try body(serving: false, hold: "catalog_material_missing")), .notServing(hold: .catalogMaterialMissing))
        XCTAssertEqual(readiness(try body(serving: true, hold: "catalog_material_missing")), .confirmed)
        // No hold, or a hold outside the closed set, is the plain fail-closed false.
        XCTAssertEqual(readiness(try body(serving: false, hold: nil)), .notServing(hold: nil))
        XCTAssertEqual(readiness(try body(serving: false, hold: "something_else")), .notServing(hold: nil))
        // A hold never upgrades or downgrades a serving verdict.
        XCTAssertEqual(readiness(try body(serving: true, hold: "model_admission_pending")), .confirmed)
        // The Bool? projection every existing reader uses is unchanged.
        XCTAssertEqual(CoordinatorReadinessClient.Readiness.notServing(hold: .modelAdmissionPending).buyerServing, false)
        XCTAssertEqual(CoordinatorReadinessClient.Readiness.confirmed.buyerServing, true)
        XCTAssertNil(CoordinatorReadinessClient.Readiness.indeterminate.buyerServing)
        XCTAssertEqual(CoordinatorReadinessClient.Readiness(booleanLiteral: false), .notServing(hold: nil))
        XCTAssertEqual(CoordinatorReadinessClient.Readiness(nilLiteral: ()), .indeterminate)
    }

    func testCoordinatorReadinessVerdictRequiresExactCatalogEnvelopeForUpdateCommit() throws {
        let requestURL = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.malibu.tech/v1/ws/provider",
            providerID: "provider-a",
            assignedID: "assigned-a"
        ))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let expected = CoordinatorReadinessClient.ExpectedCatalogEnvelope(
            releaseID: "release-a",
            policyVersion: "policy-a",
            candidateSHA256: String(repeating: "a", count: 64),
            signerKeyID: "operator-2026-01",
            rowIdentity: String(repeating: "b", count: 64)
        )
        func body(overrides: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = [
                "provider_id": "provider-a",
                "assigned_id": "assigned-a",
                "buyer_serving": true,
                "catalog_admission_mode": "current",
                "catalog_evidence_source": "provider_reported",
                "catalog_release_id": "release-a",
                "catalog_policy_version": "policy-a",
                "catalog_candidate_sha256": String(repeating: "a", count: 64),
                "catalog_signer_key_id": "operator-2026-01",
                "catalog_row_identity": String(repeating: "b", count: 64),
            ]
            for (key, value) in overrides { object[key] = value }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: try body(), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "assigned-a", expected: expected
        ), true)
        for mismatch in [
            ["provider_id": "configured-alias"],
            ["assigned_id": "assigned-b"],
            ["catalog_release_id": "release-b"],
            ["catalog_policy_version": "policy-b"],
            ["catalog_candidate_sha256": String(repeating: "c", count: 64)],
            ["catalog_signer_key_id": "operator-other"],
            ["catalog_row_identity": String(repeating: "d", count: 64)],
        ] {
            XCTAssertNil(CoordinatorReadinessClient.verdict(
                data: try body(overrides: mismatch),
                response: response,
                requestURL: requestURL,
                providerID: "provider-a",
                assignedID: "assigned-a",
                expected: expected
            ))
        }
        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: try body(overrides: ["catalog_admission_mode": "previous"]),
            response: response,
            requestURL: requestURL,
            providerID: "provider-a",
            assignedID: "assigned-a",
            expected: expected
        ), true)
    }

    func testCoordinatorReadinessRetryUsesProviderScopedJitterAndRetryAfter() {
        let first = CoordinatorReadinessClient.retryDelayNanoseconds(
            providerID: "provider-a",
            retryAfterHeader: "1"
        )
        let second = CoordinatorReadinessClient.retryDelayNanoseconds(
            providerID: "provider-b",
            retryAfterHeader: "1"
        )
        XCTAssertGreaterThanOrEqual(first, 1_050_000_000)
        XCTAssertLessThanOrEqual(first, 1_300_000_000)
        XCTAssertNotEqual(first, second)
    }

    func testSpecDecodeStatusSuppressesTelemetryOnRuntimeGenerationMismatch() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()

        let body = RouterHandler.statusResponse(
            snap,
            providerID: "provider-a",
            coordinatorURL: nil,
            specDecodeTelemetryMatchesRuntime: false
        )

        XCTAssertEqual(body["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(body["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(body["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertEqual(body["spec_decode_drafted_tokens_since_last"] as? Int, 0)
        XCTAssertEqual(body["spec_decode_accepted_tokens_since_last"] as? Int, 0)
        XCTAssertTrue(body["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusSuppressesTelemetryWhenRuntimeNotRequestEligible() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let snap = await status.snapshot()

        let fields = RouterHandler.specDecodeTelemetryFields(snap, runtimeEligible: false)

        XCTAssertEqual(fields["spec_decode_enabled"] as? Bool, false)
        XCTAssertTrue(fields["spec_decode_draft_model_id"] is NSNull)
        XCTAssertTrue(fields["spec_decode_num_draft_tokens"] is NSNull)
        XCTAssertEqual(fields["spec_decode_drafted_tokens_since_last"] as? Int, 0)
        XCTAssertEqual(fields["spec_decode_accepted_tokens_since_last"] as? Int, 0)
        XCTAssertTrue(fields["spec_decode_acceptance_rate"] is NSNull)
    }

    func testSpecDecodeStatusWindowAggregatesAndResetsWithRequestWindow() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-1")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                settlementDisposition: .eligibleOwner,
                specDecodeDraftedTokens: 10,
                specDecodeAcceptedTokens: 4,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-1"
        )

        let snap = await status.snapshot(resetWindow: true)
        XCTAssertEqual(snap.requestsServedSinceLast, 1)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 10)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 4)
        XCTAssertEqual(try XCTUnwrap(snap.specDecodeAcceptanceRate), 0.4, accuracy: 0.000_001)

        let afterReset = await status.snapshot()
        XCTAssertEqual(afterReset.requestsServedSinceLast, 0)
        XCTAssertEqual(afterReset.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(afterReset.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(afterReset.specDecodeAcceptanceRate)
    }

    func testSpecDecodeConfigResetDisablesAndClearsWindowOnTargetSwap() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let startedAt = await status.beginRequest(requestID: "r-1")
        let generation = await status.currentSpecDecodeGeneration()
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                settlementDisposition: .eligibleOwner,
                specDecodeDraftedTokens: 8,
                specDecodeAcceptedTokens: 6,
                specDecodeGeneration: generation
            ),
            failed: false,
            requestID: "r-1"
        )

        await status.setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)

        let snap = await status.snapshot()
        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertNil(snap.specDecodeDraftModelID)
        XCTAssertNil(snap.specDecodeNumDraftTokens)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
    }

    func testSpecDecodeLateOldGenerationCompletionDoesNotPollutePostSwapWindow() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: makeCapacity(),
            specDecodeDraftModelID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            specDecodeNumDraftTokens: 3
        )
        let oldGeneration = await status.currentSpecDecodeGeneration()

        await status.setSpecDecodeConfig(draftModelID: nil, numDraftTokens: nil)
        let startedAt = await status.beginRequest(requestID: "old-r-1")
        await status.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(
                content: "late",
                finishReason: "stop",
                promptTokens: 2,
                completionTokens: 1,
                settlementDisposition: .eligibleOwner,
                specDecodeDraftedTokens: 12,
                specDecodeAcceptedTokens: 9,
                specDecodeGeneration: oldGeneration
            ),
            failed: false,
            requestID: "old-r-1"
        )

        let snap = await status.snapshot()
        XCTAssertFalse(snap.specDecodeEnabled)
        XCTAssertEqual(snap.specDecodeDraftedTokensSinceLast, 0)
        XCTAssertEqual(snap.specDecodeAcceptedTokensSinceLast, 0)
        XCTAssertNil(snap.specDecodeAcceptanceRate)
    }

    func testSpecDecodeDraftModelIDRedactsLocalPaths() {
        let local = "/Users/test/.cache/huggingface/hub/models--draft"
        let redacted = ProviderStatus.publicSpecDecodeDraftModelID(local)

        XCTAssertNotEqual(redacted, local)
        XCTAssertTrue(redacted?.hasPrefix("local:") ?? false)
        XCTAssertEqual(redacted?.count, "local:".count + 32)
        XCTAssertEqual(
            ProviderStatus.publicSpecDecodeDraftModelID("mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"),
            "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
        )
    }

    func testTokenCountersAccumulateAcrossRequests() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())

        let firstStarted = await status.beginRequest(requestID: "r-1")
        await status.finishRequest(
            startedAt: firstStarted,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 625,
                completionTokens: 14,
                settlementDisposition: .eligibleOwner,
            ),
            failed: false,
            requestID: "r-1"
        )

        let secondStarted = await status.beginRequest(requestID: "r-2")
        await status.finishRequest(
            startedAt: secondStarted,
            completion: CompletionResult(
                content: "again",
                finishReason: "stop",
                promptTokens: 141,
                completionTokens: 545,
                settlementDisposition: .eligibleOwner,
            ),
            failed: false,
            requestID: "r-2"
        )

        let snap = await status.snapshot()
        XCTAssertEqual(snap.requestsTotal, 2)
        XCTAssertEqual(snap.inputTokensToday, 766)
        XCTAssertEqual(snap.outputTokensToday, 559)
        XCTAssertEqual(snap.inputTokensAllTime, 766)
        XCTAssertEqual(snap.outputTokensAllTime, 559)
    }

    func testTokenCountersIgnoreFailedRequestsWithoutCompletion() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let started = await status.beginRequest(requestID: "r-1")
        await status.finishRequest(startedAt: started, completion: nil, failed: true, requestID: "r-1")

        let snap = await status.snapshot()
        XCTAssertEqual(snap.requestsTotal, 1)
        XCTAssertEqual(snap.inputTokensToday, 0)
        XCTAssertEqual(snap.outputTokensToday, 0)
        XCTAssertEqual(snap.inputTokensAllTime, 0)
        XCTAssertEqual(snap.outputTokensAllTime, 0)
    }

    func testStatusResponseExposesTokenCounters() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let started = await status.beginRequest(requestID: "r-1")
        await status.finishRequest(
            startedAt: started,
            completion: CompletionResult(
                content: "ok",
                finishReason: "stop",
                promptTokens: 100,
                completionTokens: 25,
                settlementDisposition: .eligibleOwner,
            ),
            failed: false,
            requestID: "r-1"
        )

        let snap = await status.snapshot()
        let body = RouterHandler.statusResponse(snap, providerID: "provider-a", coordinatorURL: nil)

        XCTAssertEqual(body["input_tokens_today"] as? Int64, 100)
        XCTAssertEqual(body["output_tokens_today"] as? Int64, 25)
        XCTAssertEqual(body["input_tokens_all_time"] as? Int64, 100)
        XCTAssertEqual(body["output_tokens_all_time"] as? Int64, 25)
    }

    func testSlotsFreeReportsZeroWhenThermallyThrottled() async {
        for state: ProcessInfo.ThermalState in [.serious, .critical] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 0, "throttled state=\(state.label) must report slots_free=0")
            XCTAssertEqual(snap.status, .busy, "throttled state=\(state.label) must report status=busy")
            XCTAssertEqual(snap.slotsTotal, 4, "slots_total is hardware capacity, must stay constant")
            XCTAssertTrue(snap.thermallyThrottled)
        }
    }

    func testSlotsFreeUnthrottledReturnsAvailableCapacity() async {
        for state: ProcessInfo.ThermalState in [.nominal, .fair] {
            let gate = ThermalGate(stateProvider: FixedThermalProvider(state: state))
            let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)
            let snap = await status.snapshot()
            XCTAssertEqual(snap.slotsFree, 4, "unthrottled state=\(state.label) must report full capacity")
            XCTAssertEqual(snap.status, .ready, "unthrottled state=\(state.label) must report status=ready")
            XCTAssertFalse(snap.thermallyThrottled)
        }
    }

    func testTransitionFromNominalToSeriousDropsSlotsToZero() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let before = await status.snapshot()
        XCTAssertEqual(before.slotsFree, 4)
        XCTAssertFalse(before.thermallyThrottled)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.slotsFree, 0)
        XCTAssertEqual(throttled.status, .busy)
        XCTAssertTrue(throttled.thermallyThrottled)

        await gate.inject(state: .fair)
        let restored = await status.snapshot()
        XCTAssertEqual(restored.slotsFree, 4)
        XCTAssertEqual(restored.status, .ready)
        XCTAssertFalse(restored.thermallyThrottled)
    }

    func testThrottleDoesNotDrainInFlightRequests() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        _ = await status.beginRequest(requestID: "r-1")
        _ = await status.beginRequest(requestID: "r-2")
        let inflightBefore = await status.snapshot()
        XCTAssertEqual(inflightBefore.requestsInFlight, 2)
        XCTAssertEqual(inflightBefore.slotsFree, 2)

        await gate.inject(state: .serious)
        let throttled = await status.snapshot()
        XCTAssertEqual(throttled.requestsInFlight, 2, "in-flight requests are NOT cancelled by throttle")
        XCTAssertEqual(throttled.slotsFree, 0, "but future admissions are gated")
    }

    func testTransitionLoggerFiresOnEdgeOnly() async {
        let gate = ThermalGate(stateProvider: FixedThermalProvider(state: .nominal))
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }

        await gate.inject(state: .nominal)
        XCTAssertEqual(recorder.count, 0, "no-op transition must not log")

        await gate.inject(state: .serious)
        await gate.inject(state: .critical)
        await gate.inject(state: .fair)
        XCTAssertEqual(recorder.transitions.map { "\($0.0.label)->\($0.1.label)" },
                       ["nominal->serious", "serious->critical", "critical->fair"])
    }

    func testSnapshotResetWindowSurvivesReentrancyDuringThermalGateAwait() async {
        // Regression for the round-1 finding: `snapshot(resetWindow:)` must
        // resolve the thermal-gate `await` BEFORE reading any window state.
        // We force the race by giving the gate a 50ms artificial delay
        // inside `isThrottled()`, then letting `finishRequest` enter the
        // actor while snapshot is suspended. If the await were AFTER the
        // window reads, the finish would be silently dropped on reset.
        let gate = ThermalGate(
            stateProvider: FixedThermalProvider(state: .nominal),
            isThrottledArtificialDelayNanos: 50_000_000
        )
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(), thermalGate: gate)

        let begin = await status.beginRequest(requestID: "r-1")
        let snapshotTask = Task { await status.snapshot(resetWindow: true) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await status.finishRequest(startedAt: begin, completion: nil, failed: false, requestID: "r-1")

        let snap = await snapshotTask.value
        XCTAssertEqual(snap.requestsServedSinceLast, 1,
                       "finishRequest landing during snapshot's await must be visible AND consumed by reset")

        let after = await status.snapshot(resetWindow: false)
        XCTAssertEqual(after.requestsServedSinceLast, 0, "window must reset cleanly after reentrant finishRequest")
    }

    func testCapacityRefreshDoesNotOverwriteLifecycleFenceAfterThermalAwait() async {
        let gate = ThermalGate(
            stateProvider: FixedThermalProvider(state: .nominal),
            isThrottledArtificialDelayNanos: 50_000_000
        )
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity(maxConcurrency: 1), thermalGate: gate)

        let beginTask = Task {
            await status.beginRequest(requestID: "r-racing")
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await status.setState(.draining, reason: "operator_pause_draining")
        _ = await beginTask.value

        let fenced = await status.snapshot()
        XCTAssertEqual(fenced.status, .draining)
        let rejected = await status.beginRequestIfAccepting(requestID: "r-after-fence")
        XCTAssertNil(rejected, "capacity refresh resuming from thermal await must not reopen admission")
    }

    func testRapidThermalTransitionsAllReachTheGate() async {
        // Regression: notifications captured at the edge feed a single
        // ordered drain task, so a rapid `.serious → .fair` doesn't drop
        // the throttled interval and its log line.
        let provider = MutableThermalProvider(initial: .nominal)
        let gate = ThermalGate(stateProvider: provider)
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }
        await gate.startObserving()

        provider.set(.serious)
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        provider.set(.fair)
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        let deadline = Date().addingTimeInterval(2.0)
        while recorder.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let labels = recorder.transitions.map { "\($0.0.label)->\($0.1.label)" }
        XCTAssertEqual(labels, ["nominal->serious", "serious->fair"],
                       "both transitions must be observed in FIFO order, including the throttled interval")
    }

    func testStartObservingReconcilesStateChangedBetweenInitAndStart() async {
        // Regression: if thermal state changes between `init` and
        // `startObserving()`, no NSNotification fires while we're listening.
        // `startObserving()` must reconcile synchronously on the actor so
        // an immediate `isThrottled()` reads the post-reconcile state with
        // no polling.
        let provider = MutableThermalProvider(initial: .nominal)
        let gate = ThermalGate(stateProvider: provider)
        let recorder = TransitionRecorder()
        await gate.setTransitionLogger { old, new in recorder.record(old: old, new: new) }

        provider.set(.serious)
        await gate.startObserving()

        let throttled = await gate.isThrottled()
        XCTAssertTrue(throttled, "isThrottled must reflect the reconciled state immediately after startObserving returns — no polling")
        XCTAssertEqual(recorder.transitions.map { "\($0.0.label)->\($0.1.label)" },
                       ["nominal->serious"],
                       "the missed-transition reconciliation must also fire the transition logger exactly once")
    }

    func testShouldThrottleThreshold() {
        XCTAssertFalse(ThermalGate.shouldThrottle(.nominal))
        XCTAssertFalse(ThermalGate.shouldThrottle(.fair))
        XCTAssertTrue(ThermalGate.shouldThrottle(.serious))
        XCTAssertTrue(ThermalGate.shouldThrottle(.critical))
    }
}

private struct FixedThermalProvider: ThermalStateProviding {
    let state: ProcessInfo.ThermalState
    func currentThermalState() -> ProcessInfo.ThermalState { state }
}

private final class MutableThermalProvider: ThermalStateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState

    init(initial: ProcessInfo.ThermalState) { self.state = initial }

    func set(_ next: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        state = next
    }

    func currentThermalState() -> ProcessInfo.ThermalState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

private final class TransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] = []

    func record(old: ProcessInfo.ThermalState, new: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        entries.append((old, new))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var transitions: [(ProcessInfo.ThermalState, ProcessInfo.ThermalState)] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}

private final class RequestCapacityReasonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(reason)
    }

    var reasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

private final class RequestCapacitySnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RequestCapacityTransitionSnapshot] = []

    func record(_ transition: RequestCapacityTransitionSnapshot) {
        lock.lock(); defer { lock.unlock() }
        entries.append(transition)
    }

    var slotsFree: [Int] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.slotsFree)
    }

    var slotsTotal: [Int] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.slotsTotal)
    }

    var states: [ProviderHealthState] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.state)
    }

    var reasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.reason)
    }
}
