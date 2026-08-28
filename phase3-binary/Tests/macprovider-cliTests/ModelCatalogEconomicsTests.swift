import Foundation
import XCTest
@testable import macprovider_cli

final class ModelCatalogEconomicsTests: XCTestCase {
    func testLocalOnlyCandidateEncodesExplicitNullMoneyFields() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            cliVersion: "test",
            cliBuildCommit: "test",
            processLaunchID: "launch-test",
            processStartedAt: inputs.rateCard.value.generatedAt,
            projectionSequence: 7,
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [:],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        XCTAssertEqual(projection.schema, "model_catalog_economics.v1")
        XCTAssertEqual(projection.projectionSequence, 7)
        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(row.admission.state, "not_offered")
        XCTAssertEqual(row.admission.source, "local_default")
        XCTAssertFalse(row.admission.catalogEconomicsPermitted)
        XCTAssertFalse(row.admission.settlementCapable)
        XCTAssertEqual(row.economicsState, "blocked")
        XCTAssertEqual(row.rateSource, "none")
        XCTAssertNil(row.promptRateUSDPerMillionTokens)
        XCTAssertNil(row.completionRateUSDPerMillionTokens)
        XCTAssertNil(row.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(row.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertFalse(row.switchAction.available)
        XCTAssertEqual(row.evaluate.unavailableReason, "use_models_evaluate")

        let encoded = try ModelSwitchingWireCodec.encode(projection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let encodedRow = try XCTUnwrap(rows.first { $0["action_model_id"] as? String == Self.candidateID })
        XCTAssertTrue(encodedRow["prompt_rate_usd_per_million_tokens"] is NSNull)
        XCTAssertTrue(encodedRow["provider_prompt_payout_usd_per_million_tokens"] is NSNull)
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertTrue(source["rate_card_signature_digest"] is NSNull)
    }

    func testCatalogPricedFreshSignedRateCardPermitsEconomicsWithoutSettlement() throws {
        let inputs = try Self.staticInputs()
        let status = Self.status(state: "catalog_priced", source: "coordinator")
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: Self.servedModelRef,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: status],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(row.admission.state, "catalog_priced")
        XCTAssertEqual(row.admission.source, "coordinator")
        XCTAssertTrue(row.admission.catalogEconomicsPermitted)
        XCTAssertFalse(row.admission.settlementCapable)
        XCTAssertEqual(row.economicsState, "trusted")
        XCTAssertEqual(row.rateSource, "live_signed")
        XCTAssertEqual(row.rateCardKey, Self.catalogModelKey)
        XCTAssertNotNil(row.promptRateUSDPerMillionTokens)
        XCTAssertNotNil(row.completionRateUSDPerMillionTokens)
        XCTAssertNotNil(row.providerShareBPS)
        XCTAssertNotNil(row.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNotNil(row.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertNotNil(row.demandWeight)
        XCTAssertTrue(row.isCurrent)
    }

    func testCoordinatorBoundCatalogIdentityClearsDiscoveryOnlyUnverifiedWarning() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate(warningCodes: [BYOMDiscoveryWarning.catalogMatchUnverified.rawValue])),
            admissionStatuses: [Self.candidateID: Self.status(state: "catalog_priced", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(row.economicsState, "trusted")
        XCTAssertFalse(row.warningCodes.contains("admission_state_missing"))
    }

    func testDuplicateCatalogCandidatesDoNotDropCoordinatorBoundRuntime() throws {
        let inputs = try Self.staticInputs()
        let blockedCandidate = Self.candidate(
            candidateID: "byom_mlx_00000000000000000000000000000000000000000000000",
            runtimeSource: "mlx_cache",
            servedModelRef: "mlx-community/gpt-oss-20b-MXFP4-Q8"
        )
        let pricedCandidate = Self.candidate(
            candidateID: "byom_ollama_0000000000000000000000000000000000000000000",
            runtimeSource: "ollama_loopback",
            servedModelRef: Self.servedModelRef
        )
        let status = Self.status(
            state: "catalog_priced",
            source: "coordinator",
            candidateID: pricedCandidate.candidateID,
            servedModelRef: pricedCandidate.servedModelRef,
            catalogModelKey: Self.catalogModelKey
        )
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidates: [blockedCandidate, pricedCandidate]),
            admissionStatuses: [pricedCandidate.candidateID: status],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let localRows = projection.rows.filter { $0.modelKey == Self.catalogModelKey && $0.actionModelID != nil }
        XCTAssertEqual(localRows.count, 2)
        let pricedRow = try XCTUnwrap(localRows.first { $0.actionModelID == pricedCandidate.candidateID })
        XCTAssertEqual(pricedRow.economicsState, "trusted")
        XCTAssertTrue(pricedRow.admission.catalogEconomicsPermitted)
        let blockedRow = try XCTUnwrap(localRows.first { $0.actionModelID == blockedCandidate.candidateID })
        XCTAssertEqual(blockedRow.economicsState, "blocked")
        XCTAssertFalse(blockedRow.admission.catalogEconomicsPermitted)
    }

    func testSettlementCapableRequiresCoordinatorSettlementState() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "settlement_capable", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertTrue(row.admission.catalogEconomicsPermitted)
        XCTAssertTrue(row.admission.settlementCapable)
        XCTAssertEqual(row.economicsState, "trusted")
        XCTAssertFalse(row.warningCodes.contains("admission_state_not_settlement_capable"))
    }

    func testCoordinatorPricingRequiresMatchingCatalogIdentity() throws {
        let inputs = try Self.staticInputs()
        let statuses = [
            Self.status(
                state: "catalog_priced",
                source: "coordinator",
                servedModelRef: Self.servedModelRef,
                catalogModelKey: nil
            ),
            Self.status(
                state: "catalog_priced",
                source: "coordinator",
                servedModelRef: Self.servedModelRef,
                catalogModelKey: "other/catalog"
            ),
            Self.status(
                state: "catalog_priced",
                source: "coordinator",
                servedModelRef: "ollama:other:latest",
                catalogModelKey: Self.catalogModelKey
            ),
        ]

        for status in statuses {
            let projection = ModelCatalogEconomicsBuilder.makeProjection(
                generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
                currentModelID: nil,
                discovery: Self.discovery(candidate: Self.candidate()),
                admissionStatuses: [Self.candidateID: status],
                demand: inputs.demand,
                candidateCatalog: inputs.candidateCatalog,
                rateCard: inputs.rateCard
            )

            let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
            XCTAssertEqual(row.admission.state, "catalog_priced")
            XCTAssertEqual(row.admission.source, "coordinator")
            XCTAssertFalse(row.admission.catalogEconomicsPermitted)
            XCTAssertFalse(row.admission.settlementCapable)
            XCTAssertEqual(row.economicsState, "blocked")
            XCTAssertEqual(row.rateSource, "none")
            XCTAssertNil(row.promptRateUSDPerMillionTokens)
            XCTAssertNil(row.providerPromptPayoutUSDPerMillionTokens)
            XCTAssertEqual(row.disabledReason, "admission_state_missing")
            XCTAssertTrue(row.warningCodes.contains("admission_state_missing"))
        }
    }

    func testFallbackAndStaleRateCardsKeepMoneyFieldsNull() throws {
        let inputs = try Self.staticInputs()
        let fallbackRateCard = AutotuneStaticSelection(
            value: inputs.rateCard.value,
            selectedBytes: inputs.rateCard.selectedBytes,
            warnings: Set([AutotuneRecommendWarning.rateCardFallbackUsed]),
            usedFallback: true,
            signerKeyID: inputs.rateCard.signerKeyID
        )
        let fallback = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "catalog_priced", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: fallbackRateCard
        )
        let fallbackRow = try XCTUnwrap(fallback.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(fallback.source.rateCardSource, "static_signed")
        XCTAssertEqual(fallbackRow.economicsState, "fallback")
        XCTAssertEqual(fallbackRow.rateSource, "static_signed")
        XCTAssertNil(fallbackRow.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertTrue(fallbackRow.warningCodes.contains("feed_fallback"))

        let fallbackDemand = AutotuneStaticSelection(
            value: inputs.demand.value,
            selectedBytes: inputs.demand.selectedBytes,
            warnings: Set([AutotuneRecommendWarning.demandRankFallbackUsed]),
            usedFallback: true,
            signerKeyID: inputs.demand.signerKeyID
        )
        let demandFallback = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "catalog_priced", source: "coordinator")],
            demand: fallbackDemand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )
        let demandFallbackRow = try XCTUnwrap(demandFallback.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(demandFallbackRow.economicsState, "fallback")
        XCTAssertNil(demandFallbackRow.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(demandFallbackRow.demandWeight)

        let stale = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(TimeInterval(ModelCatalogEconomicsBuilder.rateCardMaxAgeSeconds + 1)),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "catalog_priced", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )
        let staleRow = try XCTUnwrap(stale.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(staleRow.economicsState, "stale")
        XCTAssertNil(staleRow.promptRateUSDPerMillionTokens)
        XCTAssertNil(staleRow.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertTrue(staleRow.warningCodes.contains("feed_stale"))
    }

    func testFeedIntegrityWarningsBlockEconomicsEvenWithCoordinatorPricing() throws {
        let inputs = try Self.staticInputs()
        let brokenRateCard = AutotuneStaticSelection(
            value: inputs.rateCard.value,
            selectedBytes: inputs.rateCard.selectedBytes,
            warnings: Set([AutotuneRecommendWarning.rateCardIntegrityFailure]),
            usedFallback: false,
            signerKeyID: inputs.rateCard.signerKeyID
        )

        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "catalog_priced", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: brokenRateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertTrue(row.admission.catalogEconomicsPermitted)
        XCTAssertEqual(row.economicsState, "blocked")
        XCTAssertEqual(row.rateSource, "none")
        XCTAssertNil(row.promptRateUSDPerMillionTokens)
        XCTAssertNil(row.providerShareBPS)
        XCTAssertTrue(row.warningCodes.contains("feed_signature_invalid"))
        XCTAssertTrue(projection.warnings.contains("feed_signature_invalid"))
    }

    private static let candidateID = "byom_test_0000000000000000000000000000000000000000000000"
    private static let catalogModelKey = "openai/gpt-oss-20b"
    private static let servedModelRef = "ollama:gpt-oss:20b"

    private static func staticInputs() throws -> (
        demand: AutotuneStaticSelection<DemandRank>,
        candidateCatalog: AutotuneStaticSelection<CandidateCatalog>,
        rateCard: AutotuneStaticSelection<RateCardProjection>
    ) {
        let demandBytes = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let rateBytes = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        return (
            AutotuneStaticSelection(
                value: try AutotuneStaticInputs.decodeDemandRank(demandBytes),
                selectedBytes: demandBytes,
                warnings: [],
                usedFallback: false,
                signerKeyID: "test"
            ),
            AutotuneStaticSelection(
                value: try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes),
                selectedBytes: candidateBytes,
                warnings: [],
                usedFallback: false,
                signerKeyID: "test"
            ),
            AutotuneStaticSelection(
                value: try AutotuneStaticInputs.decodeRateCard(rateBytes),
                selectedBytes: rateBytes,
                warnings: [],
                usedFallback: false,
                signerKeyID: "test"
            )
        )
    }

    private static func discovery(candidate: BYOMDiscoveryWire.Candidate) -> BYOMDiscoveryWire {
        discovery(candidates: [candidate])
    }

    private static func discovery(candidates: [BYOMDiscoveryWire.Candidate]) -> BYOMDiscoveryWire {
        BYOMDiscoveryWire(
            generatedAt: "2027-01-15T08:00:00Z",
            cliVersion: "test",
            projectionSequence: 1,
            adapters: [
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "ollama",
                    status: "available",
                    originClass: "loopback",
                    warningCodes: []
                ),
            ],
            candidates: candidates,
            warnings: []
        )
    }

    private static func candidate(
        candidateID: String = candidateID,
        runtimeSource: String = "ollama",
        servedModelRef: String = servedModelRef,
        catalogModelKey: String? = catalogModelKey,
        readinessState: String = "ready",
        fitState: String = "fits",
        admissionState: String = "not_offered",
        admissionSource: String = "local_default",
        warningCodes: [String] = []
    ) -> BYOMDiscoveryWire.Candidate {
        BYOMDiscoveryWire.Candidate(
            candidateID: candidateID,
            runtimeSource: runtimeSource,
            displayName: "GPT OSS 20B",
            servedModelRef: servedModelRef,
            catalogModelKey: catalogModelKey,
            identityState: catalogModelKey == nil ? "provider_asserted" : "catalog_matched",
            locality: "local",
            estimatedGB: 13.0,
            contextWindowTokens: 131_072,
            capabilities: .unknown,
            readinessState: readinessState,
            fitState: fitState,
            evaluationState: "not_evaluated",
            admissionState: admissionState,
            admissionStateSource: admissionSource,
            providerGuidance: BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.discovery.ready",
                stateMeaningKey: "byom.discovery.local_only",
                nextAction: "evaluate",
                transitionReasonCode: nil,
                earningPathClass: "local_inventory_only"
            ),
            warningCodes: warningCodes
        )
    }

    private static func status(state: String, source: String) -> BYOMAdmissionStatusWire {
        status(
            state: state,
            source: source,
            candidateID: Self.candidateID,
            servedModelRef: Self.servedModelRef,
            catalogModelKey: Self.catalogModelKey
        )
    }

    private static func status(
        state: String,
        source: String,
        candidateID: String = candidateID,
        servedModelRef: String,
        catalogModelKey: String?
    ) -> BYOMAdmissionStatusWire {
        BYOMAdmissionStatusWire(
            schema: "model_admission_status.v1",
            generatedAt: "2027-01-15T08:00:00Z",
            cliVersion: "test",
            providerID: "provider-byom-a",
            candidateID: candidateID,
            servedModelRef: servedModelRef,
            catalogModelKey: catalogModelKey,
            admissionState: state,
            admissionStateSource: source,
            coordinatorEventID: source == "coordinator" ? "event-test" : nil,
            stateObservedAt: source == "coordinator" ? "2027-01-15T08:00:00Z" : nil,
            providerGuidance: BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.admission.\(state)",
                stateMeaningKey: "byom.admission.not_earning",
                nextAction: "wait_for_coordinator",
                transitionReasonCode: nil,
                earningPathClass: state == "settlement_capable" ? "settlement_capable" : "no_earning_path_in_v0_1"
            ),
            allowedNextStates: [],
            warnings: []
        )
    }
}
