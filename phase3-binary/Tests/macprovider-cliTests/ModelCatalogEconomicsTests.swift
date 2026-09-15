import Foundation
import XCTest
import CryptoKit
@testable import macprovider_cli

final class ModelCatalogEconomicsTests: XCTestCase {
    func testLocalOnlyCandidateEncodesExplicitNullMoneyFields() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: Self.date("2027-01-15T08:01:00Z"),
            cliVersion: "test",
            cliBuildCommit: "test",
            processLaunchID: "launch-test",
            processStartedAt: Self.date("2027-01-15T08:00:00Z"),
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
        XCTAssertTrue(row.evaluate.available)
        XCTAssertEqual(row.evaluate.transactionKind, "evaluate_model")

        let encoded = try ModelSwitchingWireCodec.encode(projection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let encodedRow = try XCTUnwrap(rows.first { $0["action_model_id"] as? String == Self.candidateID })
        XCTAssertTrue(encodedRow["prompt_rate_usd_per_million_tokens"] is NSNull)
        XCTAssertTrue(encodedRow["provider_prompt_payout_usd_per_million_tokens"] is NSNull)
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertTrue(source["rate_card_signature_digest"] is NSNull)
    }

    func testProjectionEmitsEvaluateOnlyForEvaluatableCandidates() throws {
        let inputs = try Self.staticInputs()
        let blockedCandidate = Self.candidate(
            candidateID: "byom_" + String(repeating: "a", count: 52),
            warningCodes: [BYOMDiscoveryWarning.requiresPreparation.rawValue]
        )
        let doesNotFitCandidate = Self.candidate(
            candidateID: "byom_" + String(repeating: "b", count: 52),
            fitState: "does_not_fit"
        )
        let unknownFitCandidate = Self.candidate(
            candidateID: "byom_" + String(repeating: "d", count: 52),
            fitState: "unknown"
        )
        let unboundCatalogCandidate = Self.candidate(
            candidateID: "byom_" + String(repeating: "c", count: 52),
            catalogModelKey: nil
        )
        let unstableCandidate = Self.candidate(
            candidateID: "byom_unstable_000000000000000000000000000000000000000000000"
        )
        let projection = ModelCatalogEconomicsBuilder.makeProjection(
            generatedAt: inputs.rateCard.value.generatedAt.addingTimeInterval(60),
            currentModelID: nil,
            discovery: Self.discovery(candidates: [
                blockedCandidate,
                doesNotFitCandidate,
                unknownFitCandidate,
                unboundCatalogCandidate,
                unstableCandidate,
                Self.candidate(),
            ]),
            admissionStatuses: [:],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let rows = projection.rows.filter { $0.actionModelID != nil }
        // Genuinely non-evaluatable candidates: unstable id, not-ready
        // (requires preparation is submit-blocking), does-not-fit. Unknown fit is
        // NOT one of these — the real gates reject only does_not_fit and allow
        // unknown (SPEC-044-R002). A missing catalog binding is likewise not
        // blocking — a stable/ready candidate is offerable as a non-earning
        // v0.1 offer.
        let blockedIDs = Set([
            blockedCandidate.candidateID,
            doesNotFitCandidate.candidateID,
            unstableCandidate.candidateID,
        ])
        let blockedRows = rows.filter { blockedIDs.contains($0.actionModelID ?? "") }
        XCTAssertEqual(blockedRows.count, 3)
        XCTAssertTrue(blockedRows.allSatisfy { $0.evaluate.available == false }, "all three negative candidates must be unavailable")
        XCTAssertTrue(blockedRows.allSatisfy { $0.evaluate.unavailableReason == "candidate_not_evaluatable" })

        // The catalog-bound stable/ready/fits candidate is evaluatable.
        let availableRow = try XCTUnwrap(rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertTrue(availableRow.evaluate.available)
        XCTAssertEqual(availableRow.evaluate.transactionKind, "evaluate_model")
        XCTAssertNotNil(availableRow.evaluate.transactionID)
        XCTAssertEqual(availableRow.evaluate.actionTimeoutSeconds, 10)
        XCTAssertFalse(availableRow.evaluate.requiresConfirmation)
        XCTAssertNil(availableRow.evaluate.unavailableReason)

        // A stable/ready/fits candidate with NO catalog binding is now also
        // evaluatable (offerable as a non-earning v0.1 offer), but its economics
        // stay non-earning: no catalog key, no payout, and not settlement_capable.
        let nonCatalogRow = try XCTUnwrap(rows.first { $0.actionModelID == unboundCatalogCandidate.candidateID })
        XCTAssertTrue(nonCatalogRow.evaluate.available)
        XCTAssertEqual(nonCatalogRow.evaluate.transactionKind, "evaluate_model")
        XCTAssertNotNil(nonCatalogRow.evaluate.transactionID)
        XCTAssertEqual(nonCatalogRow.evaluate.actionTimeoutSeconds, 10)
        XCTAssertNil(nonCatalogRow.evaluate.unavailableReason)
        XCTAssertNil(nonCatalogRow.rateCardKey)
        XCTAssertNotEqual(nonCatalogRow.providerGuidance.earningPathClass, "settlement_capable")
        XCTAssertFalse(nonCatalogRow.admission.settlementCapable)
        XCTAssertNil(nonCatalogRow.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(nonCatalogRow.providerCompletionPayoutUSDPerMillionTokens)

        // A stable/ready candidate whose fit is UNKNOWN is evaluatable — the
        // gate rejects only does_not_fit and allows unknown (SPEC-044-R002). Its
        // economics stay non-earning like the nil-catalog positive.
        let unknownFitRow = try XCTUnwrap(rows.first { $0.actionModelID == unknownFitCandidate.candidateID })
        XCTAssertTrue(unknownFitRow.evaluate.available)
        XCTAssertEqual(unknownFitRow.evaluate.transactionKind, "evaluate_model")
        XCTAssertNotNil(unknownFitRow.evaluate.transactionID)
        XCTAssertEqual(unknownFitRow.evaluate.actionTimeoutSeconds, 10)
        XCTAssertNil(unknownFitRow.evaluate.unavailableReason)
        XCTAssertNotEqual(unknownFitRow.providerGuidance.earningPathClass, "settlement_capable")
        XCTAssertFalse(unknownFitRow.admission.settlementCapable)
        XCTAssertNil(unknownFitRow.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(unknownFitRow.providerCompletionPayoutUSDPerMillionTokens)
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


    func testV2ProjectionBindsProviderGuidanceAndStorageFailClosed() throws {
        let inputs = try Self.staticInputs()
        let status = Self.status(state: "catalog_priced", source: "coordinator")
        let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
            generatedAt: Self.date("2027-01-15T08:01:00Z"),
            cliVersion: "test",
            cliBuildCommit: "test",
            processLaunchID: "launch-test",
            processStartedAt: Self.date("2027-01-15T08:00:00Z"),
            projectionSequence: 9,
            currentModelID: Self.servedModelRef,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: status],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        XCTAssertEqual(projection.schema, "model_catalog_economics.v2")
        XCTAssertEqual(projection.projectionSequence, 9)
        XCTAssertEqual(projection.source.projectionProtocolVersion, "model_catalog_economics.v2")
        XCTAssertEqual(projection.storage.schema, "model_catalog_storage.v1")
        XCTAssertEqual(projection.storage.configuredLegacyAccountingState, "unavailable")
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 0)
        XCTAssertEqual(projection.cleanupTargets, [])

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        let statusText = try ModelSwitchingWireCodec.encode(status)
        XCTAssertEqual(row.candidateID, Self.candidateID)
        XCTAssertEqual(row.providerGuidance?.stateLabelKey, "byom.admission.catalog_priced")
        XCTAssertEqual(row.guidanceBinding?.sourceSchema, "model_admission_status.v1")
        XCTAssertEqual(row.guidanceBinding?.sourceSHA256, Self.sha256Hex(Data(statusText.utf8)))
        XCTAssertEqual(row.guidanceBinding?.sourceCoordinatorEventID, "event-test")
        XCTAssertEqual(row.guidanceBinding?.candidateID, Self.candidateID)
        XCTAssertEqual(row.guidanceBinding?.admissionSource, "coordinator")
        XCTAssertEqual(row.guidanceBinding?.admissionState, "catalog_priced")
        XCTAssertFalse(row.prepare.available)
        XCTAssertNil(row.prepare.artifactIdentityDigest)
        XCTAssertEqual(row.prepare.unavailableReason, "no_cli_transaction_available")
        XCTAssertFalse(row.cleanupPublished.available)
        XCTAssertEqual(row.cleanupPublished.unavailableReason, "cleanup_unavailable_without_private_store")

        let encoded = try ModelSwitchingWireCodec.encode(projection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let encodedRow = try XCTUnwrap(rows.first { $0["action_model_id"] as? String == Self.candidateID })
        let prepare = try XCTUnwrap(encodedRow["prepare"] as? [String: Any])
        XCTAssertTrue(prepare.keys.contains("artifact_identity_digest"))
        XCTAssertTrue(prepare["artifact_identity_digest"] is NSNull)
        let cleanupPublished = try XCTUnwrap(encodedRow["cleanup_published"] as? [String: Any])
        XCTAssertTrue(cleanupPublished.keys.contains("artifact_identity_digest"))
        XCTAssertTrue(cleanupPublished["artifact_identity_digest"] is NSNull)
    }

    func testV2ProjectionBindsFreshLocalDiscoveryGuidanceDigest() throws {
        let inputs = try Self.staticInputs()
        let discovery = Self.discovery(candidate: Self.candidate())
        let discoveryText = try ModelSwitchingWireCodec.encode(discovery)
        let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
            generatedAt: Self.date("2027-01-15T08:01:00Z"),
            currentModelID: nil,
            discovery: discovery,
            admissionStatuses: [:],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(row.providerGuidance?.stateLabelKey, "byom.discovery.ready")
        XCTAssertEqual(row.guidanceBinding?.sourceSchema, "provider_byom_discovery.v1")
        XCTAssertEqual(row.guidanceBinding?.sourceSHA256, Self.sha256Hex(Data(discoveryText.utf8)))
        XCTAssertEqual(row.guidanceBinding?.sourceProjectionSequence, 1)
        XCTAssertNil(row.guidanceBinding?.sourceCoordinatorEventID)
        XCTAssertEqual(row.guidanceBinding?.candidateID, Self.candidateID)
        XCTAssertEqual(row.guidanceBinding?.admissionSource, "local_default")
        XCTAssertEqual(row.guidanceBinding?.admissionState, "not_offered")
    }


    func testV2CatalogOnlyRowHasNoCandidateOrEconomicsAuthority() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
            generatedAt: Self.date("2027-01-15T08:01:00Z"),
            currentModelID: nil,
            discovery: Self.discovery(candidates: []),
            admissionStatuses: [:],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.modelKey == Self.catalogModelKey })
        XCTAssertNil(row.actionModelID)
        XCTAssertNil(row.candidateID)
        XCTAssertNil(row.providerGuidance)
        XCTAssertNil(row.guidanceBinding)
        XCTAssertEqual(row.economicsState, "unavailable")
        XCTAssertEqual(row.rateSource, "none")
        XCTAssertNil(row.providerGuidance)
        XCTAssertNil(row.guidanceBinding)
        XCTAssertNil(row.promptRateUSDPerMillionTokens)
        XCTAssertNil(row.demandWeight)
        XCTAssertFalse(row.prepare.available)
        XCTAssertEqual(row.prepare.unavailableReason, "no_local_candidate")
    }

    func testV2OfferRejectedIsNonActionableAndRemovesPricing() throws {
        let inputs = try Self.staticInputs()
        let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
            generatedAt: Self.date("2027-01-15T08:01:00Z"),
            currentModelID: nil,
            discovery: Self.discovery(candidate: Self.candidate()),
            admissionStatuses: [Self.candidateID: Self.status(state: "offer_rejected", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard
        )

        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertEqual(row.admission.state, "offer_rejected")
        XCTAssertFalse(row.admission.catalogEconomicsPermitted)
        XCTAssertFalse(row.admission.settlementCapable)
        XCTAssertEqual(row.economicsState, "unavailable")
        XCTAssertEqual(row.rateSource, "none")
        XCTAssertNil(row.providerGuidance)
        XCTAssertNil(row.guidanceBinding)
        XCTAssertNil(row.promptRateUSDPerMillionTokens)
        XCTAssertNil(row.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(row.demandWeight)
        XCTAssertNil(row.readyProviderCount)
        XCTAssertFalse(row.prepare.available)
        XCTAssertEqual(row.prepare.unavailableReason, "action_unavailable")
        XCTAssertEqual(row.switchAction.unavailableReason, "action_unavailable")
    }

    func testV2RejectsStaleFutureAndMismatchedCoordinatorGuidanceBinding() throws {
        let inputs = try Self.staticInputs()
        let cases: [(String, BYOMAdmissionStatusWire)] = [
            ("stale", Self.status(state: "catalog_priced", source: "coordinator", generatedAt: "2027-01-15T07:54:59Z")),
            ("future", Self.status(state: "catalog_priced", source: "coordinator", generatedAt: "2027-01-15T08:01:01Z")),
            ("cross-candidate", Self.status(
                state: "catalog_priced",
                source: "coordinator",
                candidateID: "byom_other_0000000000000000000000000000000000000000000000",
                servedModelRef: Self.servedModelRef,
                catalogModelKey: Self.catalogModelKey
            )),
            ("cross-model", Self.status(
                state: "catalog_priced",
                source: "coordinator",
                candidateID: Self.candidateID,
                servedModelRef: "ollama:other-model:latest",
                catalogModelKey: Self.catalogModelKey
            )),
            ("cross-catalog", Self.status(
                state: "catalog_priced",
                source: "coordinator",
                candidateID: Self.candidateID,
                servedModelRef: Self.servedModelRef,
                catalogModelKey: "openai/other-model"
            )),
        ]

        for (name, status) in cases {
            let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
                generatedAt: Self.date("2027-01-15T08:01:00Z"),
                currentModelID: nil,
                discovery: Self.discovery(candidate: Self.candidate()),
                admissionStatuses: [Self.candidateID: status],
                demand: inputs.demand,
                candidateCatalog: inputs.candidateCatalog,
                rateCard: inputs.rateCard
            )

            let row = try XCTUnwrap(
                projection.rows.first { $0.actionModelID == Self.candidateID },
                "missing row for \(name)"
            )
            XCTAssertNil(row.providerGuidance, name)
            XCTAssertNil(row.guidanceBinding, name)
            XCTAssertFalse(row.admission.catalogEconomicsPermitted, name)
            XCTAssertFalse(row.admission.settlementCapable, name)
            XCTAssertEqual(row.economicsState, "unavailable", name)
            XCTAssertEqual(row.rateSource, "none", name)
            XCTAssertNil(row.promptRateUSDPerMillionTokens, name)
            XCTAssertNil(row.providerPromptPayoutUSDPerMillionTokens, name)
            XCTAssertNil(row.demandWeight, name)
            XCTAssertTrue(row.warningCodes.contains("source_binding_invalid"), name)
            XCTAssertEqual(row.prepare.unavailableReason, "source_binding_invalid", name)
        }
    }

    func testV2RejectsStaleAndFutureLocalDiscoveryGuidanceBinding() throws {
        let inputs = try Self.staticInputs()
        let cases: [(String, BYOMDiscoveryWire)] = [
            ("stale", Self.discovery(generatedAt: "2027-01-15T07:54:59Z", candidates: [Self.candidate()])),
            ("future", Self.discovery(generatedAt: "2027-01-15T08:01:01Z", candidates: [Self.candidate()])),
        ]

        for (name, discovery) in cases {
            let projection = ModelCatalogEconomicsBuilder.makeProjectionV2(
                generatedAt: Self.date("2027-01-15T08:01:00Z"),
                currentModelID: nil,
                discovery: discovery,
                admissionStatuses: [:],
                demand: inputs.demand,
                candidateCatalog: inputs.candidateCatalog,
                rateCard: inputs.rateCard
            )

            let row = try XCTUnwrap(
                projection.rows.first { $0.actionModelID == Self.candidateID },
                "missing row for \(name)"
            )
            XCTAssertNil(row.providerGuidance, name)
            XCTAssertNil(row.guidanceBinding, name)
            XCTAssertFalse(row.admission.catalogEconomicsPermitted, name)
            XCTAssertFalse(row.admission.settlementCapable, name)
            XCTAssertEqual(row.economicsState, "unavailable", name)
            XCTAssertEqual(row.rateSource, "none", name)
            XCTAssertTrue(row.warningCodes.contains("source_binding_invalid"), name)
            XCTAssertEqual(row.prepare.unavailableReason, "source_binding_invalid", name)
        }
    }


    func testV2ProjectionPublishesCleanupTargetFromRootValidatedPrivateStore() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-reclaimable")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "a", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.storage.managedV3PublishedBytes, 4_096)
        XCTAssertEqual(projection.storage.managedV3ReclaimableBytes, 4_096)
        XCTAssertEqual(projection.storage.managedV3ObjectCount, 1)
        XCTAssertEqual(projection.storage.configuredLegacyAccountingState, "not_configured")
        XCTAssertEqual(projection.storage.configuredLegacyProtectedBytes, 0)
        XCTAssertEqual(projection.storage.configuredLegacyOtherDeviceBytes, 0)
        XCTAssertEqual(projection.storage.managedBudgetChargeBytes, 4_096)
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 1_400_000)
        XCTAssertEqual(projection.storage.availableManagedBudgetBytes, 1_395_904)
        XCTAssertEqual(projection.storage.managedBudgetSource, "default")
        XCTAssertFalse(projection.storage.managedV3OverflowDetected)
        let cleanupTarget = try XCTUnwrap(projection.cleanupTargets.first)
        XCTAssertEqual(projection.cleanupTargets.count, 1)
        XCTAssertEqual(cleanupTarget.artifactIdentityDigest, target.artifactIdentityDigest)
        XCTAssertEqual(cleanupTarget.keepSetStatus, "reclaimable")
        XCTAssertTrue(cleanupTarget.cleanup.available)
        XCTAssertEqual(cleanupTarget.cleanup.transactionKind, "cleanup_published_artifact")
        XCTAssertEqual(cleanupTarget.cleanup.artifactIdentityDigest, target.artifactIdentityDigest)
        XCTAssertEqual(cleanupTarget.cleanup.estimatedBytes, 4_096)
        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertFalse(row.cleanupPublished.available)
        XCTAssertEqual(row.cleanupPublished.unavailableReason, "cleanup_unavailable_without_private_store")
    }

    func testV2ProjectionPublishesProtectedTargetWithoutCleanupAuthority() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-protected")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "p", estimatedBytes: 8_192, keepSetStatus: .protected)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.storage.managedV3PublishedBytes, 8_192)
        XCTAssertEqual(projection.storage.managedV3ReclaimableBytes, 0)
        XCTAssertEqual(projection.storage.managedV3ObjectCount, 1)
        let cleanupTarget = try XCTUnwrap(projection.cleanupTargets.first)
        XCTAssertEqual(cleanupTarget.keepSetStatus, "protected")
        XCTAssertEqual(cleanupTarget.protectedReason, "current_model")
        XCTAssertFalse(cleanupTarget.cleanup.available)
        XCTAssertNil(cleanupTarget.cleanup.artifactIdentityDigest)
        XCTAssertNil(cleanupTarget.cleanup.estimatedBytes)
        let row = try XCTUnwrap(projection.rows.first { $0.actionModelID == Self.candidateID })
        XCTAssertFalse(row.cleanupPublished.available)
    }

    func testV2ProjectionPublishesMixedInventorySortedByDigestAndDefaultBudget() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-mixed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let first = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "m1", estimatedBytes: 6_000, keepSetStatus: .reclaimable)
        let second = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "m2", estimatedBytes: 7_000, keepSetStatus: .protected)
        let sorted = [first, second].sorted { $0.artifactIdentityDigest < $1.artifactIdentityDigest }
        try Self.writeInventory(sorted, fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 10_000
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.cleanupTargets.map(\.artifactIdentityDigest), sorted.map(\.artifactIdentityDigest))
        XCTAssertEqual(projection.storage.managedV3PublishedBytes, 13_000)
        XCTAssertEqual(projection.storage.managedV3ReclaimableBytes, 6_000)
        XCTAssertEqual(projection.storage.managedBudgetChargeBytes, 13_000)
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 7_000)
        XCTAssertEqual(projection.storage.availableManagedBudgetBytes, 0)
    }

    func testV2ProjectionUsesConfiguredBudgetWhenSelected() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-configured-budget")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "cb", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 0,
            configuredBudgetBytes: 9_000
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.storage.managedBudgetSource, "configured")
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 9_000)
        XCTAssertEqual(projection.storage.managedBudgetChargeBytes, 4_096)
        XCTAssertEqual(projection.storage.availableManagedBudgetBytes, 4_904)
        XCTAssertEqual(projection.cleanupTargets.count, 1)
    }

    func testV2ProjectionAcceptsMaximumConfiguredBudget() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-configured-budget-max")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "cbm", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 1,
            configuredBudgetBytes: Int64(ModelPreparationContracts.maxEstimatedBytes)
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.storage.managedBudgetSource, "configured")
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, Int64(ModelPreparationContracts.maxEstimatedBytes))
        XCTAssertEqual(projection.storage.managedBudgetChargeBytes, 4_096)
        XCTAssertEqual(
            projection.storage.availableManagedBudgetBytes,
            Int64(ModelPreparationContracts.maxEstimatedBytes) - 4_096
        )
        XCTAssertEqual(projection.cleanupTargets.count, 1)
    }

    func testV2ProjectionRejectsInvalidConfiguredBudgetWithoutFallingBackToDefault() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-invalid-configured-budget")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "icb", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let cases: [(String, Int64)] = [
            ("zero", 0),
            ("negative", -1),
            ("over-limit", Int64(ModelPreparationContracts.maxEstimatedBytes) + 1),
        ]

        for (name, configuredBudgetBytes) in cases {
            let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
                store: fixture.store,
                rootLocator: boot.snapshot.rootLocator,
                volumeCapacityBytes: 2_000_000,
                configuredBudgetBytes: configuredBudgetBytes
            )
            let projection = try Self.v2Projection(privateStorage: snapshot)

            Self.assertUnavailableStorage(projection.storage, overflow: false, file: #filePath, line: #line)
            XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 0, name)
            XCTAssertEqual(projection.storage.managedBudgetSource, "default", name)
            XCTAssertEqual(projection.cleanupTargets, [], name)
        }
    }

    func testV2ProjectionConfiguredBudgetSaturatesAvailableBudgetAtZero() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-configured-budget-saturated")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "cbs", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000,
            configuredBudgetBytes: 1
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        XCTAssertEqual(projection.storage.managedBudgetSource, "configured")
        XCTAssertEqual(projection.storage.globalManagedBudgetBytes, 1)
        XCTAssertEqual(projection.storage.managedBudgetChargeBytes, 4_096)
        XCTAssertEqual(projection.storage.availableManagedBudgetBytes, 0)
        XCTAssertEqual(projection.cleanupTargets.count, 1)
    }

    func testV2ProjectionRejectsWrongRootAndMalformedStoreInventory() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-wrong-root")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "w", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let drifted = try StorePayloadFactory.driftedRoot(from: boot.snapshot.rootLocator)
        let wrongRoot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: drifted,
            volumeCapacityBytes: 2_000_000
        )
        let wrongRootProjection = try Self.v2Projection(privateStorage: wrongRoot)
        Self.assertUnavailableStorage(wrongRootProjection.storage, overflow: false)
        XCTAssertEqual(wrongRootProjection.cleanupTargets, [])

        try Self.writeHostileInventoryEnvelopePayload(
            Data("{\"schema\":\"model_catalog_published_inventory.v1\"}".utf8),
            fixture: fixture,
            generation: 2
        )
        let malformed = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000
        )
        let malformedProjection = try Self.v2Projection(privateStorage: malformed)
        Self.assertUnavailableStorage(malformedProjection.storage, overflow: false)
        XCTAssertEqual(malformedProjection.cleanupTargets, [])
        let encoded = try ModelSwitchingWireCodec.encode(malformedProjection)
        XCTAssertFalse(encoded.contains(fixture.root.path))
        XCTAssertFalse(encoded.contains(boot.snapshot.rootLocator.canonicalPath))
    }

    func testV2ProjectionRejectsBadCleanupBindingFailClosed() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-bad-binding")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "b", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        let payload = try Self.inventoryPayload(root: boot.snapshot.rootLocator, targets: [target])
        let mutated = try Self.mutatingInventoryPayload(payload) { object in
            var targets = object["targets"] as! [[String: Any]]
            var first = targets[0]
            var cleanup = first["cleanup"] as! [String: Any]
            cleanup["estimated_bytes"] = 4_095
            first["cleanup"] = cleanup
            targets[0] = first
            object["targets"] = targets
        }
        try Self.writeHostileInventoryEnvelopePayload(mutated, fixture: fixture, generation: 1)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000
        )

        let projection = try Self.v2Projection(privateStorage: snapshot)

        Self.assertUnavailableStorage(projection.storage, overflow: false)
        XCTAssertEqual(projection.cleanupTargets, [])
    }

    func testV2ProjectionRejectsInvalidVolumeCapacityAndReportsExplicitOverflow() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-overflow")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "o", estimatedBytes: 4_096, keepSetStatus: .reclaimable)
        try Self.writeInventory([target], fixture: fixture, boot: boot)

        let invalidBudget = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 0
        )
        let invalidBudgetProjection = try Self.v2Projection(privateStorage: invalidBudget)
        Self.assertUnavailableStorage(invalidBudgetProjection.storage, overflow: false)
        XCTAssertEqual(invalidBudgetProjection.cleanupTargets, [])

        let hugeCapacity = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: Int64.max
        )
        let hugeCapacityProjection = try Self.v2Projection(privateStorage: hugeCapacity)
        XCTAssertEqual(hugeCapacityProjection.storage.globalManagedBudgetBytes, Int64(ModelPreparationContracts.maxEstimatedBytes))
        XCTAssertEqual(hugeCapacityProjection.storage.availableManagedBudgetBytes, Int64(ModelPreparationContracts.maxEstimatedBytes) - target.estimatedBytes)
        XCTAssertEqual(hugeCapacityProjection.storage.managedBudgetSource, "default")

        let overflow = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000,
            overflowDetected: true
        )
        let overflowProjection = try Self.v2Projection(privateStorage: overflow)
        Self.assertUnavailableStorage(overflowProjection.storage, overflow: true)
        XCTAssertEqual(overflowProjection.cleanupTargets, [])
    }

    func testV2ProjectionNeverAttachesRowCleanupByCurrentCatalogFields() throws {
        let fixture = try StoreFixture.make("model-catalog-v2-storage-row-cleanup")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let boot = try fixture.store.bootstrapWithLockCustody()
        defer { boot.lockCustody.close() }
        let target = try Self.cleanupTarget(root: boot.snapshot.rootLocator, suffix: "r", estimatedBytes: 4_096, keepSetStatus: .reclaimable, modelKey: Self.catalogModelKey)
        try Self.writeInventory([target], fixture: fixture, boot: boot)
        let snapshot = ModelCatalogEconomicsBuilder.loadPrivateStorageSnapshot(
            store: fixture.store,
            rootLocator: boot.snapshot.rootLocator,
            volumeCapacityBytes: 2_000_000
        )

        let offeredProjection = try Self.v2Projection(privateStorage: snapshot)
        XCTAssertEqual(offeredProjection.cleanupTargets.count, 1)
        XCTAssertTrue(offeredProjection.rows.allSatisfy { $0.cleanupPublished.available == false })

        let offerRejectedProjection = try Self.v2Projection(
            privateStorage: snapshot,
            admissionStatuses: [Self.candidateID: Self.status(state: "offer_rejected", source: "coordinator")]
        )
        XCTAssertEqual(offerRejectedProjection.cleanupTargets.count, 1)
        XCTAssertTrue(offerRejectedProjection.rows.allSatisfy { $0.cleanupPublished.available == false })
    }



    private static let candidateID = "byom_abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst"
    private static let catalogModelKey = "openai/gpt-oss-20b"
    private static let servedModelRef = "ollama:gpt-oss:20b"

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            fatalError("invalid test timestamp: \(value)")
        }
        return date
    }


    private static func v2Projection(
        privateStorage: ModelCatalogEconomicsBuilder.PrivateStorageSnapshot?,
        admissionStatuses: [String: BYOMAdmissionStatusWire]? = nil
    ) throws -> ModelCatalogEconomicsV2Wire {
        let inputs = try staticInputs()
        return ModelCatalogEconomicsBuilder.makeProjectionV2(
            generatedAt: date("2027-01-15T08:01:00Z"),
            cliVersion: "test",
            cliBuildCommit: "test",
            processLaunchID: "launch-test",
            processStartedAt: date("2027-01-15T08:00:00Z"),
            projectionSequence: 10,
            currentModelID: servedModelRef,
            discovery: discovery(candidate: candidate()),
            admissionStatuses: admissionStatuses ?? [candidateID: status(state: "catalog_priced", source: "coordinator")],
            demand: inputs.demand,
            candidateCatalog: inputs.candidateCatalog,
            rateCard: inputs.rateCard,
            privateStorage: privateStorage
        )
    }

    private static func writeInventory(
        _ targets: [ModelPreparationCleanupTarget],
        fixture: StoreFixture,
        boot: (snapshot: ModelPreparationPrivateStore.BootstrapSnapshot, lockCustody: ModelPreparationPrivateStore.LockCustody)
    ) throws {
        let payload = try inventoryPayload(root: boot.snapshot.rootLocator, targets: targets)
        try fixture.store.writeRecord(
            kind: .publishedInventory,
            payload: payload,
            generation: 1,
            rootLocator: boot.snapshot.rootLocator,
            lockCustody: boot.lockCustody
        )
    }

    private static func writeHostileInventoryEnvelopePayload(
        _ payload: Data,
        fixture: StoreFixture,
        generation: Int
    ) throws {
        let state = fixture.authority.appendingPathComponent("state", isDirectory: true)
        let target = state.appendingPathComponent(ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .publishedInventory))
        let envelope: [String: Any] = [
            "schema": "model_catalog_private_state_envelope.v1",
            "record_kind": ModelPreparationPrivateStateEnvelopeKind.publishedInventory.rawValue,
            "target_leaf": ModelPreparationPrivateStateEnvelope.expectedTargetLeaf(for: .publishedInventory),
            "writer_uuid": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "generation": generation,
            "payload_base64": payload.base64EncodedString(),
            "payload_sha256": sha256Hex(payload)
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func inventoryPayload(root: ModelPreparationRootLocator, targets: [ModelPreparationCleanupTarget]) throws -> Data {
        try ModelPreparationContracts.encode(
            try ModelPreparationInventoryRecord(root: root, targets: targets, generatedAt: "2027-01-15T08:00:00Z"),
            maxBytes: ModelPreparationContracts.inventoryMaxBytes
        )
    }

    private static func cleanupTarget(
        root: ModelPreparationRootLocator,
        suffix: String,
        estimatedBytes: Int64,
        keepSetStatus: ModelPreparationKeepSetStatus,
        modelKey: String? = nil
    ) throws -> ModelPreparationCleanupTarget {
        let receiptSHA = sha256Hex(Data("receipt-\(suffix)".utf8))
        let display = "Display \(suffix)"
        let revision = "revision-\(suffix)"
        let artifact = "artifact-\(suffix)"
        let release = "release-\(suffix)"
        let digest = try ModelPreparationContracts.artifactIdentityDigest(
            displayModelID: display,
            modelRevision: revision,
            artifactID: artifact,
            releaseID: release,
            rootIdentityDigest: root.rootIdentityDigest,
            receiptSHA256: receiptSHA
        )
        let action: ModelPreparationAction
        let protectedReason: String?
        switch keepSetStatus {
        case .reclaimable:
            action = try ModelPreparationAction(
                available: true,
                requiresConfirmation: true,
                transactionKind: .cleanupPublishedArtifact,
                transactionID: uuidForSuffix(suffix),
                actionTimeoutSeconds: 60,
                estimatedBytes: estimatedBytes,
                unavailableReason: nil,
                artifactIdentityDigest: digest
            )
            protectedReason = nil
        case .protected:
            action = try ModelPreparationAction(
                available: false,
                requiresConfirmation: false,
                transactionKind: nil,
                transactionID: nil,
                actionTimeoutSeconds: nil,
                estimatedBytes: nil,
                unavailableReason: "current_model",
                artifactIdentityDigest: nil
            )
            protectedReason = "current_model"
        }
        return try ModelPreparationCleanupTarget(
            artifactIdentityDigest: digest,
            displayModelID: display,
            modelRevision: revision,
            artifactID: artifact,
            releaseID: release,
            modelKey: modelKey,
            eventModelKey: "catalog/model-\(suffix)",
            rootIdentityDigest: root.rootIdentityDigest,
            receiptSHA256: receiptSHA,
            estimatedBytes: estimatedBytes,
            keepSetStatus: keepSetStatus,
            protectedReason: protectedReason,
            cleanup: action
        )
    }

    private static func uuidForSuffix(_ suffix: String) -> String {
        let byte = UInt8(suffix.utf8.reduce(0) { (Int($0) + Int($1)) % 10 })
        return "10000000-0000-4000-8000-00000000000\(byte)"
    }

    private static func mutatingInventoryPayload(
        _ payload: Data,
        mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func assertUnavailableStorage(
        _ storage: ModelCatalogEconomicsV2Wire.Storage,
        overflow: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(storage.managedV3PublishedBytes, file: file, line: line)
        XCTAssertNil(storage.managedV3ReclaimableBytes, file: file, line: line)
        XCTAssertNil(storage.managedV3ObjectCount, file: file, line: line)
        XCTAssertNil(storage.managedBudgetChargeBytes, file: file, line: line)
        XCTAssertNil(storage.availableManagedBudgetBytes, file: file, line: line)
        XCTAssertEqual(storage.configuredLegacyAccountingState, "unavailable", file: file, line: line)
        XCTAssertEqual(storage.managedV3OverflowDetected, overflow, file: file, line: line)
    }

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

    private static func discovery(
        generatedAt: String = "2027-01-15T08:00:00Z",
        candidates: [BYOMDiscoveryWire.Candidate]
    ) -> BYOMDiscoveryWire {
        BYOMDiscoveryWire(
            generatedAt: generatedAt,
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

    private static func status(
        state: String,
        source: String,
        generatedAt: String = "2027-01-15T08:00:00Z"
    ) -> BYOMAdmissionStatusWire {
        status(
            state: state,
            source: source,
            generatedAt: generatedAt,
            candidateID: Self.candidateID,
            servedModelRef: Self.servedModelRef,
            catalogModelKey: Self.catalogModelKey
        )
    }

    private static func status(
        state: String,
        source: String,
        generatedAt: String = "2027-01-15T08:00:00Z",
        candidateID: String = candidateID,
        servedModelRef: String,
        catalogModelKey: String?
    ) -> BYOMAdmissionStatusWire {
        BYOMAdmissionStatusWire(
            schema: "model_admission_status.v1",
            generatedAt: generatedAt,
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
