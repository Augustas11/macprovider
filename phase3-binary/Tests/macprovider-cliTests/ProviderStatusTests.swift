import Foundation
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

    private func makeCapacity(maxConcurrency: Int = 4) -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: maxConcurrency)
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
            coordinatorURL: "wss://coordinator.streamvc.live/provider/ws",
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
            coordinatorURL: "wss://coordinator.streamvc.live/ws/provider",
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
            coordinatorURL: "wss://coordinator.streamvc.live/ws/provider",
            catalogStatus: context
        )
        let rejected = RouterHandler.statusResponse(
            await status.snapshot(),
            providerID: "provider-a",
            coordinatorURL: "wss://coordinator.streamvc.live/ws/provider",
            catalogStatus: context,
            coordinatorBuyerServing: false
        )

        XCTAssertEqual(unknown["network_state"] as? String, "buyer_serving_unknown")
        XCTAssertEqual(unknown["buyer_serving_authority"] as? String, "unknown")
        XCTAssertEqual(rejected["network_state"] as? String, "not_buyer_serving")
        XCTAssertEqual(rejected["buyer_serving_authority"] as? String, "coordinator")
    }

    func testCoordinatorReadinessURLUsesPublicReadinessEndpoint() throws {
        let url = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.streamvc.live/v1/ws/provider?ignored=true",
            providerID: "provider a",
            assignedID: "session-a"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "coordinator.streamvc.live")
        XCTAssertEqual(components.path, "/v1/pool/check")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? []), [
            "provider_id": "provider a",
            "assigned_id": "session-a",
            "details": "readiness",
        ])
        XCTAssertNil(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "http://coordinator.streamvc.live/v1/ws/provider",
            providerID: "provider-a",
            assignedID: "session-a"
        ))
    }

    func testCoordinatorReadinessVerdictRejectsRedirectsAndNonAdmittedServingClaims() throws {
        let requestURL = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.streamvc.live/v1/ws/provider",
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
        XCTAssertEqual(CoordinatorReadinessClient.verdict(
            data: body(mode: "legacy", serving: false), response: response, requestURL: requestURL, providerID: "provider-a", assignedID: "session-a"
        ), false)
    }

    func testCoordinatorReadinessVerdictRequiresExactCatalogEnvelopeForUpdateCommit() throws {
        let requestURL = try XCTUnwrap(CoordinatorReadinessClient.readinessURL(
            coordinatorURL: "wss://coordinator.streamvc.live/v1/ws/provider",
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
