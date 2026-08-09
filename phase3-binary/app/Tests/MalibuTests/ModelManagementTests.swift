import XCTest
import Darwin
@testable import Malibu

final class ModelManagementTests: XCTestCase {
    func testCatalogValidationAllowsNoCurrentModel() throws {
        let document = MalibuModelsListDocument(
            schemaVersion: "models_list.v1",
            generatedAt: "2026-08-08T00:00:00Z",
            source: "control_socket",
            warmSwapAvailable: true,
            currentModelID: nil,
            rows: [row(id: "org/model", state: "idle", weightsPresentLocally: true, fit: "fits")]
        )

        XCTAssertNoThrow(try document.validated())
    }

    func testCatalogValidationAcceptsCLIResponseWithFractionalTimestamp() throws {
        let document = MalibuModelsListDocument(
            schemaVersion: "models_list.v1",
            generatedAt: ModelTestTimestamp.fractional,
            source: "control_socket",
            warmSwapAvailable: true,
            currentModelID: nil,
            rows: [row(id: "org/model", state: "idle", weightsPresentLocally: true, fit: "fits")]
        )

        XCTAssertNoThrow(try document.validated())
    }

    func testCatalogDecodeRejectsMissingNullableFields() throws {
        let json = """
        {"schema_version":"models_list.v1","generated_at":"2026-08-08T00:00:00Z","source":"control_socket","warm_swap_available":true,"current_model_id":null,"rows":[{"model_id":"org/model","display_id":"org/model","action_model_id":"org/model","state":"idle","weights_present_locally":true,"source":"status_response","estimated_gb":null}]}
        """

        XCTAssertThrowsError(try JSONDecoder().decode(MalibuModelsListDocument.self, from: Data(json.utf8)))
    }

    func testCatalogValidationRejectsCaseVariantDuplicateActionIDs() throws {
        let document = MalibuModelsListDocument(
            schemaVersion: "models_list.v1",
            generatedAt: "2026-08-08T00:00:00Z",
            source: "control_socket",
            warmSwapAvailable: true,
            currentModelID: nil,
            rows: [
                row(id: "Org/Model", state: "idle", weightsPresentLocally: true, fit: "fits"),
                row(id: "org/model", state: "idle", weightsPresentLocally: true, fit: "fits"),
            ]
        )

        XCTAssertThrowsError(try document.validated())
    }

    func testRowClassificationKeepsUninstalledModelsOutOfSwitchPath() {
        let row = MalibuModelRow(
            row: row(id: "org/model", state: "idle", weightsPresentLocally: false, fit: "fits"),
            currentModelID: "other/model",
            warmSwapAvailable: true
        )

        XCTAssertEqual(row.category, .needsPreparation)
        XCTAssertEqual(row.action, .evaluate)
    }

    func testRowClassificationBlocksModelsThatDoNotFit() {
        let row = MalibuModelRow(
            row: row(id: "org/model", state: "idle", weightsPresentLocally: true, fit: "wont_fit"),
            currentModelID: "other/model",
            warmSwapAvailable: true
        )

        XCTAssertEqual(row.category, .blocked)
        XCTAssertEqual(row.action, .none)
    }

    func testReclassificationMovesPreviousCurrentModelBackToReady() {
        let row = MalibuModelRow(
            row: row(id: "org/model", state: "warm", weightsPresentLocally: true, fit: "fits"),
            currentModelID: "org/model",
            warmSwapAvailable: true
        )

        let reclassified = row.reclassified(currentModelID: "other/model", warmSwapAvailable: true)

        XCTAssertEqual(reclassified.category, .ready)
        XCTAssertEqual(reclassified.action, .switchModel)
    }

    func testPowerMonitorPreservesObservationTimestamp() {
        let observedAt = Date(timeIntervalSince1970: 1_754_611_200)
        let monitor = MalibuPowerMonitor {
            MalibuPowerSample(state: .external, observedAt: observedAt)
        }

        XCTAssertEqual(monitor.sample(), MalibuPowerSample(state: .external, observedAt: observedAt))
    }

    func testCapabilityManifestRequiresFloorVersionAndDeclaredSchemas() throws {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        let tier = try XCTUnwrap(manifest.tiers[MalibuModelCapabilityManifest.readySwitch])
        let capabilities = tier.localStatusCapabilities
            .union(tier.commandSchemas)
            .union(tier.controlFrameSchemas)
        let fresh = MalibuModelPeerEvidence(
            binaryVersion: tier.firstSupportingBinaryVersion,
            capabilities: capabilities,
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: Date(),
            observationValidForMS: 5_000,
            observationFresh: true
        )
        XCTAssertTrue(manifest.supports(MalibuModelCapabilityManifest.readySwitch, peer: fresh))

        let belowFloor = MalibuModelPeerEvidence(
            binaryVersion: "1.8.89",
            capabilities: capabilities,
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: Date(),
            observationValidForMS: 5_000,
            observationFresh: true
        )
        XCTAssertFalse(manifest.supports(MalibuModelCapabilityManifest.readySwitch, peer: belowFloor))
    }

    func testPeerEvidenceExpiresEvenWhenInitialSnapshotWasFresh() {
        let observedAt = Date(timeIntervalSinceNow: -60)
        let peer = MalibuModelPeerEvidence(
            binaryVersion: "1.8.90",
            capabilities: ["model_status_v1"],
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: observedAt,
            observationValidForMS: 5_000,
            observationFresh: true
        )

        XCTAssertFalse(peer.isFresh())
    }

    func testPeerEvidenceUsesProviderLeaseNotDisplayRetention() {
        let observedAt = Date(timeIntervalSinceNow: -6)
        let peer = MalibuModelPeerEvidence(
            binaryVersion: "1.8.90",
            capabilities: ["model_status_v1"],
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: observedAt,
            observationValidForMS: 5_000,
            observationFresh: true
        )

        XCTAssertFalse(peer.isFresh())
    }

    private func row(
        id: String,
        state: String,
        weightsPresentLocally: Bool,
        fit: String
    ) -> MalibuModelsListDocument.Row {
        MalibuModelsListDocument.Row(
            modelID: id,
            displayID: id,
            actionModelID: id,
            state: state,
            weightsPresentLocally: weightsPresentLocally,
            source: "status_response",
            fit: fit,
            estimatedGB: 4.0
        )
    }
}

private enum ModelTestTimestamp {
    static let fractional = "2026-08-08T00:00:00.123Z"
}
