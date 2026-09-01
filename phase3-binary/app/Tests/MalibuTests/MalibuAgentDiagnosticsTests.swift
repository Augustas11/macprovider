import Foundation
import XCTest
@testable import Malibu

final class MalibuAgentDiagnosticsTests: XCTestCase {
    @MainActor
    func testWatchdogHomeACLFindingDoesNotScheduleAutoRepairBeforeProtectedCapability() async throws {
        let now = Date()
        let snapshot = Self.freshReadySnapshot(now: now)
        let repairRecorder = RepairRunnerRecorder()
        let agent = MalibuAgent(
            initialSnapshot: snapshot,
            providerSoftwareRepairRunner: { onLogLine in
                await repairRecorder.record()
                await onLogLine("unexpected provider software repair")
            }
        )
        agent.allowHomeACLAutoRepairForTest()

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        agent.applyProviderLogTailsForTest(
            providerLogLines: [],
            watchdogLogLines: ["autoupdate recovery_error=acl_write_rejected:\(homePath)"],
            now: now
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        let status = AgentSnapshotPresenter.publicStatus(agent.snapshot)
        let repairInvocationCount = await repairRecorder.snapshot()
        XCTAssertEqual(repairInvocationCount, 0)
        XCTAssertFalse(agent.providerSoftwareRepairTaskScheduledForTest)
        XCTAssertTrue(agent.snapshot.providerSoftwareRepairRecommended)
        XCTAssertEqual(agent.snapshot.diagnosticFindings.map(\.signatureID), [.autoupdateHomeACLRejected])
        XCTAssertEqual(status.title, "Provider is ready")
        XCTAssertEqual(status.executableAction, .exportDiagnostics)
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(agent.snapshot))
        XCTAssertTrue(status.safeNextAction?.contains("repair pending") == true)
        XCTAssertFalse(status.safeNextAction?.contains("Repair provider software.") == true)
    }

    @MainActor
    func testProviderSoftwareRepairFailureAutoAssemblesV2RedactedBundle() async throws {
        let bundleNow = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = Self.freshReadySnapshot(now: Date())
        snapshot.providerSoftwareRepairRecommended = true
        snapshot.localStatusCapabilities.insert(ProviderSoftwareRepairCapabilityGate.repairFromProtectedSource)
        let bundleRecorder = DiagnosticsBundleRecorder()
        let agent = MalibuAgent(
            initialSnapshot: snapshot,
            providerSoftwareRepairRunner: { onLogLine in
                await onLogLine("provider_token=must-not-export")
                throw CLIInstallRunner.Error.nonZeroExit(7)
            },
            recoveryDiagnosticsBundleWriter: { snapshot, providerLogLines, _, launchdNeedsRepair, appVersion in
                let data = try ProviderDiagnosticsBundle.make(
                    snapshot: snapshot,
                    providerLogLines: providerLogLines,
                    watchdogLogURL: nil,
                    appVersion: appVersion,
                    launchdNeedsRepair: launchdNeedsRepair,
                    now: bundleNow
                )
                bundleRecorder.record(data)
                return URL(fileURLWithPath: "/tmp/malibu-recovery-failure.json")
            }
        )

        await agent.repairProviderSoftware()

        let data = try XCTUnwrap(bundleRecorder.snapshot())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(
            agent.snapshot.providerSoftwareRepairLastError,
            "Provider software install failed (exit 7). Your provider identity was not changed."
        )
        XCTAssertTrue(text.contains("\"schema\" : \"malibu.provider-diagnostics.v2\""), text)
        XCTAssertTrue(text.contains("\"schema_version\" : 2"), text)
        XCTAssertTrue(text.contains("\"diagnostic_findings\""), text)
        XCTAssertTrue(text.contains("[redacted]"), text)
        XCTAssertFalse(text.contains("must-not-export"), text)
    }

    @MainActor
    func testFailedProviderSoftwareRepairDoesNotResuggestRepairUntilFreshACLEvidence() async throws {
        let observedAt = Date()
        var snapshot = Self.freshReadySnapshot(now: observedAt)
        snapshot.localStatusCapabilities.insert(ProviderSoftwareRepairCapabilityGate.repairFromProtectedSource)
        let repairRecorder = RepairRunnerRecorder()
        let agent = MalibuAgent(
            initialSnapshot: snapshot,
            providerSoftwareRepairRunner: { _ in
                await repairRecorder.record()
                throw CLIInstallRunner.Error.nonZeroExit(17)
            },
            recoveryDiagnosticsBundleWriter: { _, _, _, _, _ in
                URL(fileURLWithPath: "/tmp/malibu-recovery-failure.json")
            }
        )
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let firstEvidence = "autoupdate recovery_error=acl_write_rejected:\(homePath)"

        agent.applyProviderLogTailsForTest(
            providerLogLines: [],
            watchdogLogLines: [firstEvidence],
            now: observedAt
        )
        XCTAssertTrue(AgentSnapshotPresenter.canRepairProviderSoftware(agent.snapshot))

        await agent.repairProviderSoftware()

        let repairInvocationCount = await repairRecorder.snapshot()
        XCTAssertEqual(repairInvocationCount, 1)
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(agent.snapshot))
        XCTAssertNotEqual(AgentSnapshotPresenter.publicStatus(agent.snapshot).executableAction, .repairProviderSoftware)

        agent.applyProviderLogTailsForTest(
            providerLogLines: [],
            watchdogLogLines: [firstEvidence],
            now: Date()
        )
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(agent.snapshot))
        XCTAssertNotEqual(AgentSnapshotPresenter.publicStatus(agent.snapshot).executableAction, .repairProviderSoftware)

        let freshEvidence = "\(firstEvidence) attempt=2"
        agent.applyProviderLogTailsForTest(
            providerLogLines: [],
            watchdogLogLines: [freshEvidence],
            now: Date()
        )
        XCTAssertTrue(AgentSnapshotPresenter.canRepairProviderSoftware(agent.snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(agent.snapshot).executableAction, .repairProviderSoftware)
    }

    private static func freshReadySnapshot(now: Date) -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "11111111-1111-4111-8111-111111111111"
        snapshot.statusObservedAt = now
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        return snapshot
    }

}

private actor RepairRunnerRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

private final class DiagnosticsBundleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func record(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
