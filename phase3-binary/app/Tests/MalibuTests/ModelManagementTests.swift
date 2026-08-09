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
        let json = recommendationJSON().replacingOccurrences(
            of: "\"warnings\":[]",
            with: "\"warnings\":[\"swap_observed_under_load\"]"
        )
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8))

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(document.isActionable)

        let thermalJSON = recommendationJSON().replacingOccurrences(
            of: "\"warnings\":[]",
            with: "\"warnings\":[\"thermal_throttled\"]"
        )
        let thermal = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(thermalJSON.utf8))
        XCTAssertNoThrow(try thermal.validated(now: ModelTestTimestamp.date))
        XCTAssertFalse(thermal.isActionable)
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
        {"schema_version":"autotune_recommend.v1","generated_at":"2026-08-09T00:00:00Z","hardware":{"machine":"Mac15,6","chip":"Apple M4 Pro","memory_gb":24,"bandwidth_tier":"B","detected":true,"os_version":"15.6","binary_version":"1.8.91"},"inputs":{"rate_card_version":"rates-v1","demand_rank_version":"demand-v1","candidate_catalog_version":"catalog-v1"},"recommended_model":"mlx-community/Qwen3-8B-4bit","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"serve_config":{"model":"mlx-community/Qwen3-8B-4bit","model_artifact_path":"/private/cache/qwen3","model_artifact_sha256":"\(hashA)","model_catalog_key":"qwen3-8b","model_catalog_model_id":"mlx-community/Qwen3-8B-4bit","model_catalog_revision":"revision","model_catalog_sha256":"\(hashB)","model_catalog_version":"catalog-v1","model_catalog_hash":"\(hashC)","kv_bits":4,"max_context_override":4096,"max_concurrency_override":1,"donor_mode":false,"draft_model":null,"draft_model_artifact_sha256":null},"candidates":[{"rank":1,"model":"mlx-community/Qwen3-8B-4bit","eligible":true,"confidence":"high","why":"Best measured provider score.","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4}],"warnings":[]}
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
