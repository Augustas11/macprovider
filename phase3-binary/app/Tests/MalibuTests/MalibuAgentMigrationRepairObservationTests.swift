import XCTest
@testable import Malibu

@MainActor
final class MalibuAgentMigrationRepairObservationTests: XCTestCase {
    func testMigrationFailureObservationUsesLocalHealthWithoutAuthorityClaims() async {
        let agent = MalibuAgent()
        let dependencies = MalibuAgent.MigrationRepairObservationDependencies(
            configExists: { true },
            providerID: { "mac" },
            httpPort: { 61_919 },
            launchdEvidenceExists: { true },
            launchdServiceOwnsListener: { $0 == 61_919 },
            fetchHealth: { _ in
                InstalledProviderMonitor.HealthSnapshot(
                    ready: true,
                    model: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                    requestsTotal: 17,
                    requestsToday: 3,
                    inputTokensToday: 101,
                    outputTokensToday: 42,
                    inputTokensAllTime: 505,
                    outputTokensAllTime: 212,
                    uptimeSeconds: 90,
                    restartCount: 1
                )
            }
        )

        let observed = await agent.observeInstalledProviderDuringMigrationRepair(
            dependencies: dependencies
        )
        XCTAssertTrue(observed)

        let snapshot = agent.snapshot
        XCTAssertTrue(snapshot.migrationRepairObservationOnly)
        XCTAssertEqual(snapshot.state, .reconnecting)
        XCTAssertEqual(snapshot.currentModelID, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(snapshot.networkState, "buyer_serving_unknown")
        XCTAssertNil(snapshot.coordinatorConnected)
        XCTAssertNil(snapshot.localProviderID)
        XCTAssertNil(snapshot.cliVersion)
        XCTAssertNil(snapshot.credentialState)
        XCTAssertNil(snapshot.credentialRestartSafe)
        XCTAssertTrue(snapshot.localStatusCapabilities.isEmpty)
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.providerMutationActionsAllowed(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.canRepairCredential(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardHeadline(snapshot),
            "Running locally — migration repair required"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Coordinator connection and buyer-serving status unknown until migration is repaired."
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsLine(snapshot),
            "Today: unavailable until migration is repaired"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.trustLine(snapshot),
            "Unknown — migration repair required"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.credentialLine(snapshot),
            "Unknown — migration repair required"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            "Unknown — migration repair required"
        )
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "n/a")
        XCTAssertTrue(AgentSnapshotPresenter.malibuFullLine(snapshot).hasPrefix("n/a MALIBU"))

        await agent.pause()
        await agent.resume()
        await agent.updateCLINow()
        await agent.repairProviderCredential()
        await agent.repairAdmissionIdentity()
        XCTAssertEqual(agent.snapshot, snapshot)

        await agent.shutdown(gracefulSeconds: 0)
    }

    func testObservedMigrationRepairPreservesOriginalFailure() async {
        let agent = MalibuAgent()
        let observed = await agent.observeInstalledProviderDuringMigrationRepair(
            dependencies: dependencies(healthReady: true),
            failureReason: "Provider identity import failed."
        )

        XCTAssertTrue(observed)
        XCTAssertEqual(
            agent.snapshot.lastError,
            "Provider identity import failed. Provider is responding locally, but coordinator connection and buyer-serving status remain unknown until migration is repaired."
        )
        await agent.shutdown(gracefulSeconds: 0)
    }

    func testMigrationFailureObservationRequiresEveryLocalEvidenceGate() async {
        let cases: [MalibuAgent.MigrationRepairObservationDependencies] = [
            dependencies(configExists: false),
            dependencies(providerID: nil),
            dependencies(httpPort: nil),
            dependencies(launchdEvidenceExists: false),
            dependencies(launchdServiceOwnsListener: false),
            dependencies(healthReady: false),
        ]

        for dependencies in cases {
            let agent = MalibuAgent()
            let observed = await agent.observeInstalledProviderDuringMigrationRepair(
                dependencies: dependencies
            )
            XCTAssertFalse(observed)
            XCTAssertEqual(agent.snapshot.state, .idle)
            XCTAssertFalse(agent.snapshot.migrationRepairObservationOnly)
            XCTAssertNil(agent.snapshot.currentModelID)
            XCTAssertNil(agent.snapshot.networkState)
            XCTAssertNil(agent.snapshot.localProviderID)
            await agent.shutdown(gracefulSeconds: 0)
        }
    }

    func testMigrationObservationFailsClosedWhenLaunchdIdentityEvidenceDisappears() async {
        var launchdEvidenceChecks = 0
        let agent = MalibuAgent()
        let dependencies = observationDependencies(
            launchdEvidenceExists: {
                launchdEvidenceChecks += 1
                // Entry and the pre-fetch poll check pass. Losing identity
                // during the health read must still reject those metrics.
                return launchdEvidenceChecks <= 2
            },
            launchdServiceOwnsListener: { _ in true }
        )

        let observed = await agent.observeInstalledProviderDuringMigrationRepair(
            dependencies: dependencies
        )
        XCTAssertTrue(observed)
        let ownershipLossObserved = await eventually {
            agent.snapshot.lastError ==
                "Local provider ownership could not be verified; migration repair is still required."
        }

        XCTAssertTrue(ownershipLossObserved)
        assertOwnershipLossSnapshot(agent.snapshot)
        await agent.shutdown(gracefulSeconds: 0)
    }

    func testMigrationObservationFailsClosedWhenLaunchdListenerOwnershipDisappears() async {
        var listenerChecks = 0
        let agent = MalibuAgent()
        let dependencies = observationDependencies(
            launchdEvidenceExists: { true },
            launchdServiceOwnsListener: { port in
                listenerChecks += 1
                return port == 61_919 && listenerChecks == 1
            }
        )

        let observed = await agent.observeInstalledProviderDuringMigrationRepair(
            dependencies: dependencies
        )
        XCTAssertTrue(observed)
        let ownershipLossObserved = await eventually {
            agent.snapshot.lastError ==
                "Local provider ownership could not be verified; migration repair is still required."
        }

        XCTAssertTrue(ownershipLossObserved)
        assertOwnershipLossSnapshot(agent.snapshot)
        await agent.shutdown(gracefulSeconds: 0)
    }

    func testUnverifiedMigrationFailurePersistsRepairStateAndOriginalError() async {
        let agent = MalibuAgent()
        let thermalState = agent.snapshot.thermalState

        agent.recordUnverifiedMigrationRepairFailure(
            "The installed provider CLI failed identity validation."
        )

        XCTAssertTrue(agent.snapshot.migrationRepairObservationOnly)
        XCTAssertEqual(agent.snapshot.state, .error)
        XCTAssertEqual(agent.snapshot.networkState, "buyer_serving_unknown")
        XCTAssertNil(agent.snapshot.coordinatorConnected)
        XCTAssertEqual(agent.snapshot.thermalState, thermalState)
        XCTAssertEqual(
            agent.snapshot.lastError,
            "The installed provider CLI failed identity validation. Local provider could not be verified; migration repair is still required."
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardHeadline(agent.snapshot),
            "Provider not verified — migration repair required"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.modelLine(agent.snapshot),
            "Not verified"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.cliVersionLine(agent.snapshot),
            "Not verified — migration repair required"
        )
        await agent.shutdown(gracefulSeconds: 0)
    }

    func testExactProviderReauthorizationClearsOnlyAuthorityBlockError() async {
        let agent = MalibuAgent()
        let thermalState = agent.snapshot.thermalState
        await agent.blockProviderAccessForReleaseAuthority("provider tuple invalid")

        agent.clearProviderReleaseAuthorityBlock()

        XCTAssertFalse(agent.snapshot.releaseAuthorityBlocked)
        XCTAssertEqual(agent.snapshot.state, .idle)
        XCTAssertNil(agent.snapshot.lastError)
        XCTAssertNil(agent.providerStartFailure)
        XCTAssertEqual(agent.snapshot.thermalState, thermalState)
        await agent.shutdown(gracefulSeconds: 0)
    }

    private func dependencies(
        configExists: Bool = true,
        providerID: String? = "mac",
        httpPort: Int? = 61_919,
        launchdEvidenceExists: Bool = true,
        launchdServiceOwnsListener: Bool = true,
        healthReady: Bool = true
    ) -> MalibuAgent.MigrationRepairObservationDependencies {
        MalibuAgent.MigrationRepairObservationDependencies(
            configExists: { configExists },
            providerID: { providerID },
            httpPort: { httpPort },
            launchdEvidenceExists: { launchdEvidenceExists },
            launchdServiceOwnsListener: { _ in launchdServiceOwnsListener },
            fetchHealth: { _ in
                InstalledProviderMonitor.HealthSnapshot(
                    ready: healthReady,
                    model: "test-model",
                    requestsTotal: nil,
                    requestsToday: nil,
                    inputTokensToday: nil,
                    outputTokensToday: nil,
                    inputTokensAllTime: nil,
                    outputTokensAllTime: nil,
                    uptimeSeconds: nil,
                    restartCount: nil
                )
            }
        )
    }

    private func observationDependencies(
        launchdEvidenceExists: @escaping @MainActor @Sendable () -> Bool,
        launchdServiceOwnsListener: @escaping @MainActor @Sendable (Int) -> Bool
    ) -> MalibuAgent.MigrationRepairObservationDependencies {
        MalibuAgent.MigrationRepairObservationDependencies(
            configExists: { true },
            providerID: { "mac" },
            httpPort: { 61_919 },
            launchdEvidenceExists: launchdEvidenceExists,
            launchdServiceOwnsListener: launchdServiceOwnsListener,
            fetchHealth: { _ in
                InstalledProviderMonitor.HealthSnapshot(
                    ready: true,
                    model: "test-model",
                    requestsTotal: 17,
                    requestsToday: 3,
                    inputTokensToday: 101,
                    outputTokensToday: 42,
                    inputTokensAllTime: 505,
                    outputTokensAllTime: 212,
                    uptimeSeconds: 90,
                    restartCount: 1
                )
            },
            pollIntervalNanoseconds: 1_000_000
        )
    }

    private func assertOwnershipLossSnapshot(
        _ snapshot: AgentSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(snapshot.migrationRepairObservationOnly, file: file, line: line)
        XCTAssertEqual(snapshot.state, .error, file: file, line: line)
        XCTAssertEqual(snapshot.networkState, "buyer_serving_unknown", file: file, line: line)
        XCTAssertNil(snapshot.coordinatorConnected, file: file, line: line)
        XCTAssertNil(snapshot.currentModelID, file: file, line: line)
        XCTAssertNil(snapshot.requestsServedAllTime, file: file, line: line)
        XCTAssertNil(snapshot.requestsServedToday, file: file, line: line)
        XCTAssertNil(snapshot.inputTokensToday, file: file, line: line)
        XCTAssertNil(snapshot.outputTokensToday, file: file, line: line)
        XCTAssertNil(snapshot.inputTokensAllTime, file: file, line: line)
        XCTAssertNil(snapshot.outputTokensAllTime, file: file, line: line)
        XCTAssertNil(snapshot.uptimeSec, file: file, line: line)
        XCTAssertNil(snapshot.restartCount, file: file, line: line)
        XCTAssertFalse(AgentSnapshotPresenter.providerMutationActionsAllowed(snapshot), file: file, line: line)
    }

    private func eventually(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
