import Foundation
import XCTest
@testable import Malibu

final class InstalledProviderReadoptionTests: XCTestCase {
    @MainActor
    func testRestartAdoptsNewValidatedServiceAndClearsExpiredStatus() async throws {
        var old = AgentSnapshot.empty
        old.state = .error
        old.lastError = "Provider local status is unavailable or stale."
        old.cliVersion = "1.8.277"
        old.serviceInstanceID = "old-instance"
        old.servicePID = 111
        old.credentialState = "expired"
        old.advertisedMaxConcurrency = 1
        old.localStatusCapabilities = ["status_observation_v1", "service_instance_v1"]
        old.statusObservationFresh = false
        let agent = MalibuAgent(
            initialSnapshot: old,
            initialProviderStartFailure: "Provider was unavailable during restart."
        )
        XCTAssertNotNil(agent.providerStartFailure)
        let status = try replacementStatus(instance: "new-instance", pid: 222, version: "1.8.277")

        await agent.applyInstalledProviderObservation(
            status: status, health: nil, expectedProviderID: "provider-a",
            launchdPID: 222, liveCodeMatches: { $0 == 222 }
        )

        XCTAssertEqual(agent.snapshot.serviceInstanceID, "new-instance")
        XCTAssertEqual(agent.snapshot.servicePID, 222)
        XCTAssertEqual(agent.snapshot.state, .serving)
        XCTAssertNil(agent.snapshot.lastError)
        XCTAssertNil(agent.providerStartFailure)
        XCTAssertEqual(agent.snapshot.credentialState, "ready")
        XCTAssertEqual(agent.snapshot.advertisedMaxConcurrency, 4)
        XCTAssertTrue(agent.snapshot.isLocalStatusObservationCurrent())
        XCTAssertFalse(agent.snapshot.diagnosticFindings.contains { $0.signatureID == .serveUnresponsive })
    }

    @MainActor
    func testUpdateAdoptsRunningVersionAndRemovesStaleUpdateOffer() async throws {
        var old = AgentSnapshot.empty
        old.state = .reconnecting
        old.cliVersion = "1.8.274"
        old.latestReleaseVersion = "1.8.277"
        old.coordinatorRecommendedVersion = "1.8.277"
        old.serviceInstanceID = "before-update"
        old.servicePID = 111
        let agent = MalibuAgent(initialSnapshot: old)
        XCTAssertTrue(AgentSnapshotPresenter.updateAvailable(old))
        let status = try replacementStatus(instance: "after-update", pid: 333, version: "1.8.277")

        await agent.applyInstalledProviderObservation(
            status: status, health: nil, expectedProviderID: "provider-a",
            launchdPID: 333, liveCodeMatches: { $0 == 333 }
        )

        XCTAssertEqual(agent.snapshot.cliVersion, "1.8.277")
        XCTAssertEqual(agent.snapshot.serviceInstanceID, "after-update")
        XCTAssertEqual(agent.snapshot.networkState, "buyer_serving")
        XCTAssertEqual(agent.snapshot.state, .serving)
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(agent.snapshot))
    }

    @MainActor
    func testReplacementStillRejectsForeignProviderPIDAndExecutable() async throws {
        let status = try replacementStatus(instance: "foreign-instance", pid: 222, version: "1.8.277")
        for (providerID, launchdPID, codeMatches) in [
            ("provider-b", 222, true),
            ("provider-a", 999, true),
            ("provider-a", 222, false),
        ] {
            var old = AgentSnapshot.empty
            old.state = .serving
            old.serviceInstanceID = "old-instance"
            old.servicePID = 111
            let agent = MalibuAgent(initialSnapshot: old)

            await agent.applyInstalledProviderObservation(
                status: status, health: nil, expectedProviderID: providerID,
                launchdPID: launchdPID, liveCodeMatches: { _ in codeMatches }
            )

            XCTAssertEqual(agent.snapshot.state, .error)
            XCTAssertNil(agent.snapshot.serviceInstanceID)
            XCTAssertEqual(agent.snapshot.lastError, "Installed provider identity does not match this Mac.")
        }
    }

    @MainActor
    func testCreativeHoldStatusRefreshesEvenWhenHealthIsUnavailable() async throws {
        let status = try replacementStatus(
            instance: "create-instance", pid: 222, version: "1.8.277",
            networkState: "not_buyer_serving", creativeState: "downloading"
        )
        let agent = MalibuAgent()

        await agent.applyInstalledProviderObservation(
            status: status, health: nil, expectedProviderID: "provider-a",
            launchdPID: 222, liveCodeMatches: { _ in true }
        )

        XCTAssertEqual(agent.snapshot.localImageGenerationState, "downloading")
        XCTAssertEqual(agent.snapshot.networkState, "not_buyer_serving")
        XCTAssertTrue(agent.snapshot.isLocalStatusObservationCurrent())
        XCTAssertNotEqual(agent.snapshot.state, .error)
    }

    private func replacementStatus(
        instance: String, pid: Int, version: String,
        networkState: String = "buyer_serving", creativeState: String = "idle"
    ) throws -> InstalledProviderMonitor.StatusSnapshot {
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let data = Data("""
        {
          "provider_id": "provider-a",
          "binary_version": "\(version)",
          "network_state": "\(networkState)",
          "local_status_contract": {
            "version": 1, "minimum_reader_version": 1,
            "lifecycle_owner": "macprovider_cli",
            "capabilities": ["service_instance_v1", "status_observation_v1", "buyer_serving_authority_v1", "credential_status_v1", "model_status_v1"]
          },
          "observation": {"id": "observation-\(instance)", "observed_at": "\(timestamp)", "valid_for_ms": 5000},
          "service_instance": {
            "instance_id": "\(instance)", "pid": \(pid), "boot_session": "boot-a",
            "started_at": "\(timestamp)", "role": "serve"
          },
          "credential": {"state": "ready", "recovery_action": "none"},
          "coordinator": {"connected": true, "recommended_binary_version": "1.8.277"},
          "capacity": {"max_concurrency": 4},
          "model_id": "test-model", "model_loaded": true,
          "local_image_generation": {"state": "\(creativeState)"}
        }
        """.utf8)
        return try XCTUnwrap(InstalledProviderMonitor.decodeStatus(data, now: now, currentBootSession: "boot-a"))
    }
}
