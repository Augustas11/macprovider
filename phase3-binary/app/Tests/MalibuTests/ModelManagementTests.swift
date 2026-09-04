import XCTest
import Darwin
@testable import Malibu

final class ModelManagementTests: XCTestCase {
    func testRecommendationTargetIdentityIsCaseInsensitive() {
        XCTAssertTrue(ModelManagementStore.recommendationTargetIsCurrent(
            "Org/Model",
            currentModelID: "org/model"
        ))
        XCTAssertFalse(ModelManagementStore.recommendationTargetIsCurrent(
            "Org/Model",
            currentModelID: "org/Other"
        ))
    }

    func testRecommendationAdoptionRequiresActionableReadyRow() {
        let ready = MalibuModelRow(
            row: row(id: "Org/Model", state: "idle", weightsPresentLocally: true, fit: "fits"),
            currentModelID: "org/other",
            warmSwapAvailable: true
        )
        XCTAssertTrue(ModelManagementStore.recommendationTargetIsReadyForAdoption(
            "org/model",
            listState: .ready,
            rows: [ready]
        ))
        XCTAssertFalse(ModelManagementStore.recommendationTargetIsReadyForAdoption(
            "org/model",
            listState: .viewOnly,
            rows: [ready]
        ))

        let unavailable = MalibuModelRow(
            row: row(id: "Org/Model", state: "idle", weightsPresentLocally: false, fit: "fits"),
            currentModelID: "org/other",
            warmSwapAvailable: true
        )
        XCTAssertFalse(ModelManagementStore.recommendationTargetIsReadyForAdoption(
            "org/model",
            listState: .ready,
            rows: [unavailable]
        ))
    }

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

    func testBackgroundSafetyFailsClosedForUnknownOrStaleSignals() {
        let now = Date(timeIntervalSince1970: 1_754_611_200)
        XCTAssertTrue(ModelManagementStore.backgroundSafetyAllows(
            power: MalibuPowerSample(state: .external, observedAt: now.addingTimeInterval(-10)),
            thermalState: .fair,
            now: now
        ))
        XCTAssertFalse(ModelManagementStore.backgroundSafetyAllows(
            power: MalibuPowerSample(state: .external, observedAt: now.addingTimeInterval(-11)),
            thermalState: .nominal,
            now: now
        ))
        XCTAssertFalse(ModelManagementStore.backgroundSafetyAllows(
            power: MalibuPowerSample(state: .external, observedAt: now),
            thermalState: nil,
            now: now
        ))
        XCTAssertFalse(ModelManagementStore.backgroundSafetyAllows(
            power: MalibuPowerSample(state: .unknown, observedAt: now),
            thermalState: .nominal,
            now: now
        ))
        XCTAssertFalse(ModelManagementStore.backgroundSafetyAllows(
            power: MalibuPowerSample(state: .battery, observedAt: now),
            thermalState: .nominal,
            now: now
        ))
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

    func testCapabilityManifestRequiresRecommendationAndAdoptionContracts() throws {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        for capability in [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.recommendationCheck,
            MalibuModelCapabilityManifest.recommendationAdoption,
        ] {
            let tier = try XCTUnwrap(manifest.tiers[capability])
            let advertised = tier.localStatusCapabilities
                .union(tier.commandSchemas)
                .union(tier.controlFrameSchemas)
            let fresh = MalibuModelPeerEvidence(
                binaryVersion: tier.firstSupportingBinaryVersion,
                capabilities: advertised,
                contractCompatible: true,
                lifecycleOwner: "macprovider_cli",
                serviceInstanceID: "instance",
                servicePID: Int(getpid()),
                observedAt: Date(),
                observationValidForMS: 5_000,
                observationFresh: true
            )
            XCTAssertTrue(manifest.supports(capability, peer: fresh))

            let missingSchema = MalibuModelPeerEvidence(
                binaryVersion: tier.firstSupportingBinaryVersion,
                capabilities: advertised.subtracting(tier.commandSchemas.prefix(1)),
                contractCompatible: true,
                lifecycleOwner: "macprovider_cli",
                serviceInstanceID: "instance",
                servicePID: Int(getpid()),
                observedAt: Date(),
                observationValidForMS: 5_000,
                observationFresh: true
            )
            XCTAssertFalse(manifest.supports(capability, peer: missingSchema))
        }
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

    @MainActor
    func testBackgroundRecommendationArgumentsAreInstalledOnlyAndNonMutating() {
        let arguments = ModelManagementStore.backgroundRecommendationArguments(
            configURL: URL(fileURLWithPath: "/private/config.yaml"),
            isolatedCacheRoot: URL(fileURLWithPath: "/private/recommendation-checks")
        )

        XCTAssertEqual(arguments, [
            "autotune", "--recommend", "--json", "--check-only", "--progress-json",
            "--installed-only", "--isolated-cache-root", "/private/recommendation-checks",
            "--no-submit-hardware-evidence", "--config", "/private/config.yaml",
        ])
        XCTAssertFalse(arguments.contains("--apply"))
        XCTAssertFalse(arguments.contains("--prefetch"))
    }

    func testRecommendationValidationAcceptsActionableInstalledResult() throws {
        let document = try JSONDecoder().decode(
            MalibuRecommendationDocument.self,
            from: Data(recommendationJSON().utf8)
        )

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertEqual(document.recommendedModel, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(document.recommendedCandidate?.confidence, "high")
        XCTAssertEqual(document.selectedExplanation?.measuredTPS, 42.5)
        XCTAssertEqual(document.selectedExplanation?.memoryFit.headroomGB, 12)
        XCTAssertEqual(document.selectedExplanation?.demandSignal.supplyDeficitMultiplier, 1.5)
        XCTAssertEqual(document.selectedExplanation?.rateSignal.providerShareBPS, 9000)
        XCTAssertTrue(document.selectedRationale?.contains("best estimated earning potential") == true)
        XCTAssertTrue(document.selectedEvidenceLines.contains { $0.contains("State ready; confidence high") })
        XCTAssertTrue(document.selectedEvidenceLines.contains { $0.contains("Measured 42.50 tok/s") })
        XCTAssertTrue(document.selectedEvidenceLines.contains { $0.contains("not accrued rewards") })
        XCTAssertEqual(document.alternativeExplanations.first?.lostReason, "lower_expected_earning_potential")
    }

    func testRecommendationValidationRejectsMismatchedSelectedExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""selected_explanation":\#(Self.explanationJSON())"#,
                with: #""selected_explanation":\#(Self.explanationJSON(summary: "Different model rationale."))"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnpairedSelectedExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #","explanation":\#(Self.explanationJSON())"#, with: "")
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsCandidateOnlySelectedExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationEvidenceLabelsCatalogEstimateThroughput() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""throughput_source":"measured""#, with: #""throughput_source":"catalog_estimate""#)
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"advisory""#)
            .replacingOccurrences(of: #""confidence":"high""#, with: #""confidence":"catalog_estimate""#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertTrue(document.selectedEvidenceLines.contains { $0.contains("Catalog estimate 42.50 tok/s") })
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationEvidenceLabelsUnavailableThroughput() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""throughput_source":"measured""#, with: #""throughput_source":"unavailable""#)
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"advisory""#)
            .replacingOccurrences(of: #""confidence":"high""#, with: #""confidence":"low""#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertTrue(document.selectedEvidenceLines.contains { $0.contains("Throughput unavailable; memory headroom") })
        XCTAssertFalse(document.selectedEvidenceLines.contains { $0.contains("Throughput unavailable 42.50 tok/s") })
        XCTAssertFalse(document.selectedEvidenceLines.contains { $0.contains("Measured 42.50 tok/s") })
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationActionabilityRequiresReadyHighMeasuredExplanation() throws {
        let advisoryJSON = recommendationJSON()
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"advisory""#)
        let advisory = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(advisoryJSON.utf8))
        XCTAssertNoThrow(try advisory.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(advisory.isActionable)

        let lowConfidenceJSON = recommendationJSON()
            .replacingOccurrences(of: #""confidence":"high""#, with: #""confidence":"medium""#)
        let lowConfidence = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(lowConfidenceJSON.utf8))
        XCTAssertThrowsError(try lowConfidence.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(lowConfidence.isActionable)
    }

    func testRecommendationActionabilityRejectsExplanationContradictions() throws {
        let localWarningJSON = recommendationJSON()
            .replacingOccurrences(
                of: #""local_health":{"warnings":[]},"confidence":"high""#,
                with: #""local_health":{"warnings":["swap_observed_under_load"]},"confidence":"high""#
            )
        let localWarning = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(localWarningJSON.utf8))
        XCTAssertThrowsError(try localWarning.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(localWarning.isActionable)

        let confidenceMismatchJSON = recommendationJSON()
            .replacingOccurrences(
                of: #""eligible":true,"confidence":"high","why":"Best measured provider score.""#,
                with: #""eligible":true,"confidence":"medium","why":"Best measured provider score.""#
            )
        let confidenceMismatch = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(confidenceMismatchJSON.utf8))
        XCTAssertThrowsError(try confidenceMismatch.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(confidenceMismatch.isActionable)
    }

    func testRecommendationValidationRejectsCandidateEvidenceMismatch() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""tokens_per_second":42.5"#, with: #""tokens_per_second":420.0"#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationValidationRejectsCoordinatedForgedEvidence() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""recommendable":true"#, with: #""recommendable":false"#)
            .replacingOccurrences(
                of: #""lost_reason":"selected_best_expected_earning_potential""#,
                with: #""lost_reason":"demand_not_recommendable""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationValidationRejectsExplanationWithoutThroughputSource() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""throughput_source":"measured","#, with: "")

        XCTAssertThrowsError(try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8)))
    }

    func testRecommendationValidationRejectsUnknownThroughputSource() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""throughput_source":"measured""#, with: #""throughput_source":"untrusted_probe""#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnsafeExplanationDisplayText() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""summary":"Selected for the best estimated earning potential on this Mac.""#,
                with: #""summary":"Guaranteed $100/day from /private/cache/provider_id.""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsParaphrasedIncomeClaim() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #"Selected for the best estimated earning potential on this Mac."#,
                with: #"This model will pay 100 USD every 24 hours regardless of demand."#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsSmuggledIncomeClaimTemplate() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #"Selected for the best estimated earning potential on this Mac."#,
                with: #"This model will pay 100 USD every week; qwen is eligible and will be ranked by earning potential."#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsOverflowMemoryFit() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""required_gb":8"#, with: #""required_gb":9223372036854775807"#)
            .replacingOccurrences(of: #""safety_margin_gb":4"#, with: #""safety_margin_gb":9223372036854775807"#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsControlCharactersInDisplayText() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""summary":"Selected for the best estimated earning potential on this Mac.""#,
                with: #""summary":"Selected for this Mac.\nApprove now.""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnknownExplanationState() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"trusted""#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnsafeAlternativeExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""summary":"Eligible, but another model has stronger estimated earning potential on this Mac.""#,
                with: #""summary":"Guaranteed hourly provider_identity payout.""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnsafeAlternativeModelID() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""model":"mlx-community/Other-Model-4bit""#,
                with: #""model":"/private/cache/provider_id""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnboundAlternativeExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""alternative_explanations":[\#(Self.alternativeJSON())]"#,
                with: #""alternative_explanations":[\#(Self.alternativeJSON(model: "mlx-community/Missing-Model-4bit"))]"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnboundDonorFallbackExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""donor_fallback_explanation":null"#,
                with: #""donor_fallback_explanation":\#(Self.explanationJSON(summary: "Fallback model would be advisory only.", lostReason: "donor_mode_fallback"))"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsUnknownRootWarning() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""warnings":[]}"#,
                with: #""warnings":["candidate_catalog_integrity_failure "]}"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationValidationRejectsUnsafeRootWarningText() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""warnings":[]}"#,
                with: #""warnings":["/private/cache/provider_id"]}"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationValidationRejectsUnsafeVisibleMetadata() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""chip":"Apple M4 Pro""#,
                with: #""chip":"/private/cache/provider_id""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsNegativeTopLevelRates() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2"#,
                with: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":-1"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsTopLevelRateMismatch() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config""#,
                with: #""prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":9.9,"serve_config""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsSelectedExplanationWithoutRecommendedModel() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit""#,
                with: #""recommended_model":null"#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationAcceptsDonorServeConfigWithoutRecommendedModel() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4"#,
                with: #""recommended_model":null,"prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null"#
            )
            .replacingOccurrences(of: #""donor_mode":false"#, with: #""donor_mode":true"#)
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #""eligible":true"#, with: #""eligible":false"#)
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"blocked""#)
            .replacingOccurrences(of: #"selected_best_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(of: #"lower_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(
                of: #"Selected for the best estimated earning potential on this Mac."#,
                with: #"No paid recommendation is available; this donor fallback remains advisory."#
            )
            .replacingOccurrences(
                of: #"Eligible, but another model has stronger estimated earning potential on this Mac."#,
                with: #"No paid recommendation is available for this row."#
            )
            .replacingOccurrences(
                of: #"Best measured provider score."#,
                with: #"No paid recommendation is available for this row."#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
        XCTAssertTrue(document.hasVisibleRecommendationFeedback)
    }

    func testRecommendationValidationRejectsNonDonorServeConfigWithoutRecommendedModel() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4"#,
                with: #""recommended_model":null,"prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null"#
            )
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testNoRecommendationDocumentKeepsWhyNotDisplayFeedback() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config":{"#,
                with: #""recommended_model":null,"prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null,"serve_config":null,"_removed":{"#
            )
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #""eligible":true"#, with: #""eligible":false"#)
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"blocked""#)
            .replacingOccurrences(of: #"selected_best_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(of: #"lower_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(
                of: #"Selected for the best estimated earning potential on this Mac."#,
                with: #"No paid recommendation is available for this Mac right now."#
            )
            .replacingOccurrences(
                of: #"Eligible, but another model has stronger estimated earning potential on this Mac."#,
                with: #"No paid recommendation is available for this row."#
            )
            .replacingOccurrences(
                of: #"Best measured provider score."#,
                with: #"No paid recommendation is available for this row."#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertTrue(document.hasVisibleRecommendationFeedback)
        XCTAssertNil(document.recommendedModel)
        XCTAssertFalse(document.isActionable)
        XCTAssertTrue(document.displayRationale?.contains("No paid recommendation is available") == true)
        XCTAssertTrue(document.displayEvidenceLines.contains { $0.contains("State blocked") })
    }

    func testNoRecommendationDocumentRejectsSelectedLookingFeedback() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config":{"#,
                with: #""recommended_model":null,"prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null,"serve_config":null,"_removed":{"#
            )
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #""eligible":true"#, with: #""eligible":false"#)
            .replacingOccurrences(of: #""warning_state":"ready""#, with: #""warning_state":"blocked""#)
            .replacingOccurrences(of: #"selected_best_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(of: #"lower_expected_earning_potential"#, with: #"demand_not_recommendable"#)
            .replacingOccurrences(
                of: #"Eligible, but another model has stronger estimated earning potential on this Mac."#,
                with: #"No paid recommendation is available for this row."#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testNoRecommendationDocumentRejectsLegacySelectedLookingWhy() throws {
        let json = recommendationJSON()
            .replacingOccurrences(
                of: #""recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config":{"#,
                with: #""recommended_model":null,"prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null,"serve_config":null,"_removed":{"#
            )
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","alternative_explanations":[\#(Self.alternativeJSON())]"#, with: #","alternative_explanations":[]"#)
            .replacingOccurrences(of: #","explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.alternativeCandidateExplanationJSON())"#, with: "")
            .replacingOccurrences(
                of: #",{"rank":2,"model":"mlx-community/Other-Model-4bit","eligible":true,"confidence":"medium","why":"Eligible, but another model has stronger estimated earning potential on this Mac.","prompt_rate_usd_per_million_tokens":0.15,"completion_rate_usd_per_million_tokens":0.25}"#,
                with: ""
            )
            .replacingOccurrences(of: #""eligible":true"#, with: #""eligible":false"#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationRejectsDuplicateRecommendedCandidates() throws {
        let duplicateCandidate = #","#
            + #"{"rank":2,"model":"mlx-community/Qwen3-8B-4bit","eligible":true,"confidence":"high","why":"Duplicate provider score.","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"explanation":\#(Self.explanationJSON())}"#
        let json = recommendationJSON()
            .replacingOccurrences(of: #"}],"warnings":[]}"#, with: #"}\#(duplicateCandidate)],"warnings":[]}"#)
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
        XCTAssertNil(document.recommendedCandidate)
    }

    func testRecommendationValidationRejectsOlderRecommendationWithoutExplanation() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","alternative_explanations":[\#(Self.alternativeJSON())]"#, with: "")
            .replacingOccurrences(of: #","donor_fallback_explanation":null"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.alternativeCandidateExplanationJSON())"#, with: "")
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertNil(document.selectedExplanation)
        XCTAssertNil(document.selectedRationale)
        XCTAssertTrue(document.selectedEvidenceLines.isEmpty)
        XCTAssertFalse(document.isActionable)
    }

    func testRecommendationValidationRejectsLegacyWeeklyEarnClaim() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","alternative_explanations":[\#(Self.alternativeJSON())]"#, with: "")
            .replacingOccurrences(of: #","donor_fallback_explanation":null"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.alternativeCandidateExplanationJSON())"#, with: "")
            .replacingOccurrences(
                of: #""why":"Best measured provider score.""#,
                with: #""why":"Earn 100 USD weekly with this model.""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertNil(document.selectedRationale)
    }

    func testRecommendationValidationRejectsUnsafeLegacyWhyText() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: #","selected_explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","alternative_explanations":[\#(Self.alternativeJSON())]"#, with: "")
            .replacingOccurrences(of: #","donor_fallback_explanation":null"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.explanationJSON())"#, with: "")
            .replacingOccurrences(of: #","explanation":\#(Self.alternativeCandidateExplanationJSON())"#, with: "")
            .replacingOccurrences(
                of: #""why":"Best measured provider score.""#,
                with: #""why":"Guaranteed $100/day from /private/cache/provider_id.""#
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testRecommendationValidationKeepsUnsupportedDraftAdvisory() throws {
        let json = recommendationJSON().replacingOccurrences(
            of: "\"draft_model\":null,\"draft_model_artifact_sha256\":null",
            with: "\"draft_model\":\"mlx-community/draft\",\"draft_model_artifact_sha256\":\"\(String(repeating: "d", count: 64))\""
        )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)
        XCTAssertNotNil(document.adoptionAdvisoryReason)
    }

    func testRecommendationValidationKeepsThermalOrSwapWarningAdvisory() throws {
        let json = recommendationJSON()
            .replacingOccurrences(of: "\"warning_state\":\"ready\"", with: "\"warning_state\":\"advisory\"")
            .replacingOccurrences(
                of: "\"warnings\":[]",
                with: "\"warnings\":[\"swap_observed_under_load\"]"
            )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)

        let thermalJSON = recommendationJSON()
            .replacingOccurrences(of: "\"warning_state\":\"ready\"", with: "\"warning_state\":\"advisory\"")
            .replacingOccurrences(
                of: "\"warnings\":[]",
                with: "\"warnings\":[\"thermal_throttled\"]"
            )
        let thermal = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(thermalJSON.utf8))
        XCTAssertNoThrow(try thermal.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(thermal.isActionable)
    }

    func testRecommendationValidationKeepsAnyRootWarningAdvisoryOnly() throws {
        for warning in [
            "candidate_catalog_fallback_used",
            "candidate_catalog_stale",
            "demand_rank_fallback_used",
            "demand_rank_stale",
            "hardware_tier_unknown",
            "rate_card_default_tier_used",
            "rate_card_fallback_used",
            "rate_card_stale",
        ] {
            let json = recommendationJSON().replacingOccurrences(
                of: #"}],"warnings":[]}"#,
                with: #"}],"warnings":["\#(warning)"]}"#
            )
            let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

            XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date), warning)
            XCTAssertFalse(document.isActionable, warning)
            XCTAssertNotNil(document.adoptionAdvisoryReason, warning)
        }
    }

    func testRecommendationValidationRejectsCatalogModelIdentityMismatch() throws {
        let json = recommendationJSON().replacingOccurrences(
            of: "\"model_catalog_model_id\":\"mlx-community/Qwen3-8B-4bit\"",
            with: "\"model_catalog_model_id\":\"mlx-community/other-model\""
        )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertThrowsError(try document.validated(now: ModelTestTimestamp.date))
    }

    func testBackgroundCheckEventRejectsDownloadPhase() throws {
        let data = Data("""
        {"schema_version":"model_recommendation_check_event.v1","type":"progress","check_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","candidate_model_id":"mlx-community/Qwen3-8B-4bit","phase":"downloading","elapsed_ms":10,"cancellable":true,"installed_only":true,"reason":null,"staging_discarded":null}
        """.utf8)
        let event = try JSONDecoder().decode(MalibuRecommendationCheckEvent.self, from: data)

        XCTAssertThrowsError(try event.validatedForBackground())
    }

    func testBackgroundCheckEventAcceptsInstalledOnlyCompletion() throws {
        let data = Data("""
        {"schema_version":"model_recommendation_check_event.v1","type":"completed","check_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","candidate_model_id":null,"phase":"completed","elapsed_ms":12,"cancellable":false,"installed_only":true,"reason":null,"staging_discarded":true}
        """.utf8)
        let event = try JSONDecoder().decode(MalibuRecommendationCheckEvent.self, from: data)

        XCTAssertNoThrow(try event.validatedForBackground())
    }

    func testBackgroundCheckEventRejectsMissingInstalledOnlyProof() throws {
        let data = Data("""
        {"schema_version":"model_recommendation_check_event.v1","type":"completed","check_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","candidate_model_id":null,"phase":"completed","elapsed_ms":12,"cancellable":false,"reason":null,"staging_discarded":true}
        """.utf8)
        let event = try JSONDecoder().decode(MalibuRecommendationCheckEvent.self, from: data)

        XCTAssertThrowsError(try event.validatedForBackground())
    }

    func testBackgroundCheckTranscriptRequiresOneAcceptedTransaction() throws {
        let accepted = try JSONDecoder().decode(
            MalibuRecommendationCheckEvent.self,
            from: Data("""
            {"schema_version":"model_recommendation_check_event.v1","type":"accepted","check_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","candidate_model_id":null,"phase":null,"elapsed_ms":0,"cancellable":false,"installed_only":true,"reason":null,"staging_discarded":null}
            """.utf8)
        )
        let wrongCompletion = try JSONDecoder().decode(
            MalibuRecommendationCheckEvent.self,
            from: Data("""
            {"schema_version":"model_recommendation_check_event.v1","type":"completed","check_id":"d13c5d4c-3e4f-47ac-b72d-7f8f172747a0","candidate_model_id":null,"phase":"completed","elapsed_ms":1,"cancellable":false,"installed_only":true,"reason":null,"staging_discarded":true}
            """.utf8)
        )
        var transcript = MalibuRecommendationCheckTranscript()

        XCTAssertNoThrow(try transcript.consume(accepted))
        XCTAssertThrowsError(try transcript.consume(wrongCompletion))
        XCTAssertNil(transcript.terminalType)
    }

    func testAdoptionEventRejectsMismatchedTargetAndUnknownRollbackState() throws {
        let mismatchedTarget = Data("""
        {"schema_version":"model_adoption_event.v1","type":"completed","transaction_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","target_model_id":"other/model","from_model_id":"incumbent/model","incumbent_model_id":"incumbent/model","phase":null,"elapsed_ms":12,"cancellable":false,"reason":null,"rollback_state":null,"config_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","backup_path":"redacted"}
        """.utf8)
        let targetEvent = try JSONDecoder().decode(MalibuModelAdoptionEvent.self, from: mismatchedTarget)
        XCTAssertThrowsError(try targetEvent.validated(target: "recommended/model"))

        let unknownRollback = Data("""
        {"schema_version":"model_adoption_event.v1","type":"failed","transaction_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","target_model_id":"recommended/model","from_model_id":"incumbent/model","incumbent_model_id":"incumbent/model","phase":"failed","elapsed_ms":12,"cancellable":false,"reason":"switch_failed","rollback_state":"unknown"}
        """.utf8)
        let rollbackEvent = try JSONDecoder().decode(MalibuModelAdoptionEvent.self, from: unknownRollback)
        XCTAssertThrowsError(try rollbackEvent.validated(target: "recommended/model"))
    }

    func testAdoptionTranscriptRejectsProgressBeforeAcceptance() throws {
        let progress = try JSONDecoder().decode(
            MalibuModelAdoptionEvent.self,
            from: Data("""
            {"schema_version":"model_adoption_event.v1","type":"progress","transaction_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","target_model_id":"recommended/model","from_model_id":"incumbent/model","incumbent_model_id":"incumbent/model","phase":"config_apply","elapsed_ms":12,"cancellable":false,"reason":null,"rollback_state":null}
            """.utf8)
        )
        var transcript = MalibuModelAdoptionTranscript()

        XCTAssertThrowsError(try transcript.consume(progress, target: "recommended/model"))
        XCTAssertNil(transcript.transactionID)
    }

    func testRecommendationScheduleUsesDailySuccessAndExponentialFailureBackoff() {
        var schedule = MalibuRecommendationSchedule()
        let start = ModelTestTimestamp.date

        schedule.recordFailure(at: start)
        XCTAssertEqual(schedule.nextEligibleAt, start.addingTimeInterval(60 * 60))
        schedule.recordFailure(at: start)
        XCTAssertEqual(schedule.nextEligibleAt, start.addingTimeInterval(2 * 60 * 60))
        schedule.recordSuccess(at: start)
        XCTAssertEqual(schedule.nextEligibleAt, start.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(schedule.consecutiveFailures, 0)
    }

    func testRecommendationSnoozeIsBoundToVisibleIdentity() throws {
        let document = try JSONDecoder().decode(
            MalibuRecommendationDocument.self,
            from: Data(recommendationJSON().utf8)
        )
        let identity = try XCTUnwrap(document.identity(currentModelID: "old-model"))
        var schedule = MalibuRecommendationSchedule()
        schedule.snooze(identity: identity, at: ModelTestTimestamp.date)

        XCTAssertTrue(schedule.suppresses(identity: identity, at: ModelTestTimestamp.date))
        let changed = MalibuRecommendationIdentity(
            recommendedModel: identity.recommendedModel,
            currentModelID: identity.currentModelID,
            rateCardVersion: "rates-v2",
            demandRankVersion: identity.demandRankVersion,
            candidateCatalogVersion: identity.candidateCatalogVersion,
            chip: identity.chip,
            memoryGB: identity.memoryGB,
            bandwidthTier: identity.bandwidthTier,
            binaryVersion: identity.binaryVersion
        )
        XCTAssertFalse(schedule.suppresses(identity: changed, at: ModelTestTimestamp.date))
        XCTAssertTrue(schedule.isEligible(at: ModelTestTimestamp.date))
    }

    @MainActor
    func testActiveRecommendationOperationsBlockRefresh() {
        XCTAssertTrue(ModelManagementStore.Operation.loadingList.blocksRefresh)
        XCTAssertTrue(ModelManagementStore.Operation.checkingRecommendation(phase: "planning").blocksRefresh)
        XCTAssertTrue(ModelManagementStore.Operation.adoptingRecommendation(target: "org/model", phase: "config_apply").blocksRefresh)
        XCTAssertFalse(ModelManagementStore.Operation.idle.blocksRefresh)
    }

    private func recommendationJSON() -> String {
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let hashC = String(repeating: "c", count: 64)
        return """
        {"schema_version":"autotune_recommend.v1","generated_at":"2026-08-09T00:00:00Z","hardware":{"machine":"Mac15,6","chip":"Apple M4 Pro","memory_gb":24,"bandwidth_tier":"B","detected":true,"os_version":"15.6","binary_version":"1.8.91"},"inputs":{"rate_card_version":"rates-v1","demand_rank_version":"demand-v1","candidate_catalog_version":"catalog-v1"},"recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config":{"model":"mlx-community/Qwen3-8B-4bit","model_artifact_path":"/private/cache/qwen3","model_artifact_sha256":"\(hashA)","model_catalog_key":"qwen3-8b","model_catalog_model_id":"mlx-community/Qwen3-8B-4bit","model_catalog_revision":"revision","model_catalog_sha256":"\(hashB)","model_catalog_version":"catalog-v1","model_catalog_hash":"\(hashC)","kv_bits":4,"max_context_override":4096,"max_concurrency_override":1,"donor_mode":false,"draft_model":null,"draft_model_artifact_sha256":null},"selected_explanation":\(Self.explanationJSON()),"alternative_explanations":[\(Self.alternativeJSON())],"donor_fallback_explanation":null,"candidates":[{"rank":1,"model":"mlx-community/Qwen3-8B-4bit","eligible":true,"confidence":"high","why":"Best measured provider score.","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"tokens_per_second":42.5,"memory_headroom_gb":12,"raw_score":38250,"explanation":\(Self.explanationJSON())},{"rank":2,"model":"mlx-community/Other-Model-4bit","eligible":true,"confidence":"medium","why":"Eligible, but another model has stronger estimated earning potential on this Mac.","prompt_rate_usd_per_million_tokens":0.15,"completion_rate_usd_per_million_tokens":0.25,"tokens_per_second":42.5,"memory_headroom_gb":12,"raw_score":1000,"explanation":\(Self.alternativeCandidateExplanationJSON())}],"warnings":[]}
        """
    }

    private static func explanationJSON(
        summary: String = "Selected for the best estimated earning potential on this Mac.",
        score: Double = 38_250,
        lostReason: String = "selected_best_expected_earning_potential",
        confidence: String = "high"
    ) -> String {
        """
        {"summary":"\(summary)","warning_state":"ready","measured_tps":42.5,"throughput_source":"measured","memory_fit":{"required_gb":8,"total_gb":24,"safety_margin_gb":4,"headroom_gb":12},"demand_signal":{"rank":7,"weight":0.65,"recommendable":true,"min_provider_target":10,"ready_provider_count":4,"supply_deficit_multiplier":1.5},"rate_signal":{"prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"provider_share_bps":9000,"provider_completion_payout_usd_per_million_tokens":0.36},"earning_potential":{"score":\(score),"kind":"relative_ranking_score","note":"Estimated earning potential only; actual rewards depend on buyer demand, uptime, accepted work, and settlement."},"local_health":{"warnings":[]},"confidence":"\(confidence)","lost_reason":"\(lostReason)"}
        """
    }

    private static func alternativeCandidateExplanationJSON() -> String {
        explanationJSON(
            summary: "Eligible, but another model has stronger estimated earning potential on this Mac.",
            score: 1_000,
            lostReason: "lower_expected_earning_potential",
            confidence: "medium"
        )
    }

    private static func alternativeJSON(model: String = "mlx-community/Other-Model-4bit") -> String {
        """
        {"rank":2,"model":"\(model)","eligible":true,"lost_reason":"lower_expected_earning_potential","summary":"Eligible, but another model has stronger estimated earning potential on this Mac.","expected_earning_potential_score":1000}
        """
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
    static let date = ISO8601DateFormatter().date(from: "2026-08-09T00:00:00Z")!
}
