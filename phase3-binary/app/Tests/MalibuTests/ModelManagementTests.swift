import XCTest
import Metal
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

    func testCatalogEconomicsValidationAcceptsTrustedCoordinatorRows() throws {
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [trustedEconomicsRowJSON()]).utf8)
        )

        XCTAssertNoThrow(try document.validated(now: ModelTestTimestamp.date))
        let mapped = try XCTUnwrap(MalibuModelRow(
            economics: document.rows[0],
            currentModelID: "other/model",
            warmSwapAvailable: true
        ))
        XCTAssertEqual(mapped.category, .networkCatalog)
        XCTAssertEqual(mapped.providerCompletionPayoutUSDPerMillionTokens, 0.36)
        XCTAssertEqual(mapped.demandRank, 7)
        XCTAssertEqual(mapped.action, .none)
    }

    func testCatalogEconomicsHidesLocalDefaultBYOMRowsForThisRelease() throws {
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [localOnlyBYOMRowJSON()]).utf8)
        )
        let validated = try document.validated(now: ModelTestTimestamp.date)

        XCTAssertNil(MalibuModelRow(
            economics: validated.rows[0],
            currentModelID: "other/model",
            warmSwapAvailable: true
        ))
    }

    func testCatalogEconomicsDecodeRejectsUnsupportedEnvelopeKeys() throws {
        let json = catalogEconomicsJSON(rows: [trustedEconomicsRowJSON()])
            .replacingOccurrences(of: #""schema":"model_catalog_economics.v1""#, with: #""schema":"model_catalog_economics.v1","provider_secret_path":"/private/tmp/key""#)

        XCTAssertThrowsError(try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(json.utf8)
        ))
    }

    func testCatalogEconomicsFailsClosedOnAnyMalformedRow() throws {
        // A projection containing ANY malformed row must fail the WHOLE decode
        // (fail-closed / closed-schema), never quarantine the bad row and still
        // render trusted rates from the rest.
        let missingNullable = trustedEconomicsRowJSON()
            .replacingOccurrences(of: #","disabled_reason":null"#, with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                missingNullable,
                trustedEconomicsRowJSON(),
            ]).utf8)
        ))

        let unknownKey = trustedEconomicsRowJSON()
            .replacingOccurrences(of: #""model_key":"qwen3-8b""#, with: #""model_key":"qwen3-8b","provider_secret_path":"/private/tmp/key""#)
        XCTAssertThrowsError(try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                unknownKey,
                trustedEconomicsRowJSON(),
            ]).utf8)
        ))
    }

    // A row that fails row-level validation is demoted to a non-economics
    // (blocked) row by rowsForMalibu — no provider payout is shown — rather than
    // rendering trusted rates. Returns the rendered provider payout for the row
    // (nil when the row was demoted / shows no economics).
    private func renderedProviderPayout(forRow rowJSON: String) throws -> Double? {
        let rows = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [rowJSON]).utf8)
        )
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        return rows.first?.providerCompletionPayoutUSDPerMillionTokens ?? nil
    }

    func testCatalogEconomicsRequiresNonEarningDisclosureForNonSettlementTrustedRow() throws {
        // A catalog_priced (non-settlement) trusted row that OMITS the non-earning
        // warning is demoted (no rates shown) — the "No provider credit yet"
        // disclosure must not depend on a possibly-omitted CLI warning.
        XCTAssertNil(try renderedProviderPayout(forRow: trustedEconomicsRowJSON(warningCodesJSON: "[]")))
        // With the warning present, the non-settlement row shows economics.
        XCTAssertNotNil(try renderedProviderPayout(forRow: trustedEconomicsRowJSON()))
        // A settlement_capable row that CONTRADICTORILY carries the non-settlement
        // warning is demoted; without it, it shows economics.
        XCTAssertNil(try renderedProviderPayout(
            forRow: trustedEconomicsRowJSON(admissionState: "settlement_capable", settlementCapable: true)
        ))
        XCTAssertNotNil(try renderedProviderPayout(
            forRow: trustedEconomicsRowJSON(admissionState: "settlement_capable", settlementCapable: true, warningCodesJSON: "[]")
        ))
    }

    func testCatalogEconomicsRejectsActionDescriptorReasonMismatch() throws {
        // An unavailable action with no reason demotes the row (no economics).
        let unavailableNoReason = #"{"available":false,"requires_confirmation":false,"transaction_kind":null,"transaction_id":null,"action_timeout_seconds":null,"estimated_bytes":null,"unavailable_reason":null}"#
        XCTAssertNil(try renderedProviderPayout(forRow: trustedEconomicsRowJSON(switchAction: unavailableNoReason)))
        // An available action carrying an unavailable reason likewise demotes it.
        let availableWithReason = #"{"available":true,"requires_confirmation":true,"transaction_kind":"switch_model","transaction_id":"c23c5d4c-3e4f-47ac-b72d-7f8f172747a0","action_timeout_seconds":20,"estimated_bytes":null,"unavailable_reason":"action_unavailable"}"#
        XCTAssertNil(try renderedProviderPayout(forRow: trustedEconomicsRowJSON(switchAction: availableWithReason)))
    }

    @MainActor
    func testCatalogProjectionRejectsStaleReplyFromOlderProcess() async throws {
        let switchAction = availableActionJSON(kind: "switch_model", timeout: 20)
        let newer = managedCatalogEconomicsJSON(
            rows: [trustedEconomicsRowJSON(switchAction: switchAction)],
            generatedAt: Self.timestamp(offset: -10)
        )
        // A late reply from an OLDER CLI process: different process_launch_id and
        // an earlier generated_at, carrying no rows.
        let olderProcess = managedCatalogEconomicsJSON(rows: [], generatedAt: Self.timestamp(offset: -120))
            .replacingOccurrences(
                of: "c13c5d4c-3e4f-47ac-b72d-7f8f172747a0",
                with: "a1111111-2222-3333-4444-555555555555"
            )
        let cli = FakeModelCLI(results: [
            ModelCLIResult(exitCode: 0, stdout: newer, stderr: ""),
            ModelCLIResult(exitCode: 0, stdout: olderProcess, stderr: ""),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.staleProcess.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])
        await store.refresh(currentModelID: "other/model", peer: peer)
        let firstRows = store.rows.map(\.id)
        XCTAssertFalse(firstRows.isEmpty)

        await store.refresh(currentModelID: "other/model", peer: peer)
        // The older-process reply must be rejected; the newer accepted rows stay,
        // rather than being cleared by the stale empty projection.
        XCTAssertEqual(store.rows.map(\.id), firstRows)
    }

    func testCatalogEconomicsRejectsDuplicateJSONKeys() throws {
        XCTAssertThrowsError(try MalibuStrictJSON.rejectDuplicateKeys(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertThrowsError(try MalibuStrictJSON.rejectDuplicateKeys(Data(#"{"x":{"k":1,"k":2}}"#.utf8)))
        XCTAssertNoThrow(try MalibuStrictJSON.rejectDuplicateKeys(Data(#"{"a":1,"b":2}"#.utf8)))
    }

    func testCatalogEconomicsRowCarriesVerifiedCatalogIdentity() throws {
        let rows = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [trustedEconomicsRowJSON()]).utf8)
        )
        .validated(now: ModelTestTimestamp.date)
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        // The coordinator-verified catalog identity (model_key) is carried
        // separately from the provider-reported display name.
        XCTAssertEqual(rows.first?.catalogVerifiedModelKey, "qwen3-8b")
        XCTAssertEqual(rows.first?.displayID, "mlx-community/Qwen3-8B-4bit")
    }

    func testSwitchableCatalogPricedRowStillShowsNonEarningDisclosure() throws {
        // A switchable catalog_priced (non-settlement) row shows rates AND is
        // actionable, but must ALSO carry the non-earning disclosure — the caveat
        // cannot be dropped just because the row is .switchModel / not blocked.
        let switchAction = availableActionJSON(kind: "switch_model", timeout: 20)
        let switchable = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [trustedEconomicsRowJSON(switchAction: switchAction)]).utf8)
        )
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        let row = try XCTUnwrap(switchable.first)
        XCTAssertEqual(row.action, .switchModel)
        XCTAssertNotNil(row.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertNotNil(row.nonEarningDisclosure)

        // A settlement_capable row shows rates but carries NO non-earning caveat.
        let settlement = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                trustedEconomicsRowJSON(admissionState: "settlement_capable", settlementCapable: true, warningCodesJSON: "[]")
            ]).utf8)
        )
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        XCTAssertNotNil(settlement.first?.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertNil(settlement.first?.nonEarningDisclosure)
    }

    func testCatalogPricedEconomicsAccessibilityLabelVoicesRatesWithFullDisclosure() throws {
        // #1381 Part C (VoiceOver): a screen-reader user must hear the
        // catalog_priced rates AND the non-earning caveat as one announcement --
        // the caveat can never be dropped from the accessibility label when the
        // rates are voiced. The view applies row.economicsAccessibilityLabel as a
        // single accessibility element (children ignored), so this pins exactly
        // what VoiceOver reads for a non-settlement priced row.
        let switchAction = availableActionJSON(kind: "switch_model", timeout: 20)
        let rows = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [trustedEconomicsRowJSON(switchAction: switchAction)]).utf8)
        )
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        let row = try XCTUnwrap(rows.first)
        let label = try XCTUnwrap(
            row.economicsAccessibilityLabel,
            "a catalog_priced row that shows rates must expose a VoiceOver economics label"
        )
        // The rates are voiced (decimal separator is locale-dependent, so match
        // the locale-independent phrasing, not a hard-coded "0.36") ...
        XCTAssertTrue(label.contains("Provider share rate: completion"), "label must voice the completion rate: \(label)")
        XCTAssertTrue(label.contains("Provider share rate: prompt"), "label must voice the prompt rate: \(label)")
        XCTAssertTrue(label.contains("per 1M tokens."), "label must voice the rate unit: \(label)")
        // The visible rate rows and the VoiceOver label share one source: every
        // visible rate line is present, verbatim, in the announcement.
        XCTAssertFalse(row.economicsRateLines.isEmpty, "a priced row must have visible rate lines")
        for rateLine in row.economicsRateLines {
            XCTAssertTrue(label.contains(rateLine), "VoiceOver label must include visible rate line '\(rateLine)': \(label)")
        }
        // ... and the FULL non-earning disclosure, verbatim, together with them.
        let disclosure = "No provider credit yet; catalog and receipt checks are still required."
        XCTAssertTrue(label.contains(disclosure), "VoiceOver label must include the full non-earning disclosure: \(label)")
        XCTAssertEqual(row.nonEarningDisclosure, disclosure, "the disclosure text drifted from the fixture")
        // The announcement is EXACTLY the visible rate lines in order followed by
        // the caveat last -- so any regression that interleaved or reordered them
        // (e.g. completion, caveat, prompt) fails, not just one that moved it
        // before the first rate.
        let expected = (row.economicsRateLines + [disclosure]).joined(separator: " ")
        XCTAssertEqual(label, expected, "VoiceOver announcement must be the rate lines in order followed by the caveat")
    }

    func testSettlementCapableEconomicsAccessibilityLabelHasRatesWithoutDisclosure() throws {
        // The settlement_capable counterpart voices its rates but carries NO
        // non-earning caveat -- the caveat is specific to non-settlement rows.
        let rows = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                trustedEconomicsRowJSON(admissionState: "settlement_capable", settlementCapable: true, warningCodesJSON: "[]")
            ]).utf8)
        )
        .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        let row = try XCTUnwrap(rows.first)
        let label = try XCTUnwrap(row.economicsAccessibilityLabel)
        XCTAssertTrue(label.contains("Provider share rate: completion"), "label must voice the completion rate: \(label)")
        XCTAssertFalse(label.contains("No provider credit yet"), "settlement_capable must NOT carry the non-earning caveat: \(label)")
        XCTAssertNil(row.nonEarningDisclosure)
    }

    func testCatalogEconomicsDegradesUnsafeActionDescriptor() throws {
        let unsafeAction = availableActionJSON(kind: "switch_model", timeout: 20, requiresConfirmation: false)
        let json = trustedEconomicsRowJSON(switchAction: unsafeAction)
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [json]).utf8)
        )

        let row = try XCTUnwrap(document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
            .first)
        XCTAssertEqual(row.category, .blocked)
        XCTAssertEqual(row.action, .none)
        XCTAssertNil(row.providerCompletionPayoutUSDPerMillionTokens)
    }

    func testCatalogEconomicsDegradesRowsWithStrongerRateSourceThanProjection() throws {
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(
                rows: [trustedEconomicsRowJSON()],
                rateCardSource: "static_signed"
            ).utf8)
        )

        let row = try XCTUnwrap(document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
            .first)
        XCTAssertEqual(row.category, .blocked)
        XCTAssertEqual(row.action, .none)
        XCTAssertNil(row.providerCompletionPayoutUSDPerMillionTokens)
    }

    func testCatalogEconomicsDegradesTrustedRowsWithBlockingWarningsOrStaleAdmission() throws {
        let staleAdmission = "2026-08-01T00:00:00Z"
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                trustedEconomicsRowJSON(warningCodesJSON: #"["feed_stale"]"#),
                trustedEconomicsRowJSON(stateObservedAt: staleAdmission),
            ]).utf8)
        )

        let rows = try document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.category == .blocked })
        XCTAssertTrue(rows.allSatisfy { $0.action == .none })
        XCTAssertTrue(rows.allSatisfy { $0.providerCompletionPayoutUSDPerMillionTokens == nil })
    }

    func testCatalogEconomicsDegradesProjectionLevelTrustWarnings() throws {
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let json = catalogEconomicsJSON(rows: [
            trustedEconomicsRowJSON(switchAction: action),
        ])
            .replacingOccurrences(of: #""warnings":[]"#, with: #""warnings":["projection_unavailable"]"#)
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(json.utf8)
        )

        let row = try XCTUnwrap(document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
            .first)
        XCTAssertEqual(row.category, .blocked)
        XCTAssertEqual(row.action, .none)
        XCTAssertNil(row.providerCompletionPayoutUSDPerMillionTokens)
    }

    func testCatalogEconomicsDegradesContradictorySwitchableRows() throws {
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let blockedRuntime = trustedEconomicsRowJSON(switchAction: action)
            .replacingOccurrences(of: #""runtime_state":"catalog""#, with: #""runtime_state":"blocked""#)
        let blockingWarning = trustedEconomicsRowJSON(
            switchAction: action,
            warningCodesJSON: #"["model_not_supported"]"#
        )
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/Warning-Blocked-4bit")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"warning-blocked""#)
        let disabledReason = trustedEconomicsRowJSON(switchAction: action)
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/Disabled-Blocked-4bit")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"disabled-blocked""#)
            .replacingOccurrences(of: #""disabled_reason":null"#, with: #""disabled_reason":"model_not_supported""#)
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                blockedRuntime,
                blockingWarning,
                disabledReason,
            ]).utf8)
        )

        let rows = try document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.category == .blocked })
        XCTAssertTrue(rows.allSatisfy { $0.action == .none })
        XCTAssertTrue(rows.allSatisfy { $0.providerCompletionPayoutUSDPerMillionTokens == nil })
    }

    func testCatalogEconomicsRejectsUnsafeProviderVisibleModelText() throws {
        let pathDisplay = trustedEconomicsRowJSON()
            .replacingOccurrences(of: #""display_model_id":"mlx-community/Qwen3-8B-4bit""#, with: #""display_model_id":"/private/tmp/will pay daily""#)
        let bidiModel = trustedEconomicsRowJSON()
            .replacingOccurrences(of: #""served_model_id":"mlx-community/Qwen3-8B-4bit""#, with: #""served_model_id":"mlx-community/\u202Eevil""#)
        let formatControlDisplay = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/Hidden\\u200EText-4bit")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"format-control""#)
        let rewardClaim = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/up to higher-paying model")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"reward-claim""#)
        let monthlyPayoutClaim = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/potential earnings $20/month")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"monthly-payout-claim""#)
        let dailyPayoutClaim = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/$20/day")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"daily-payout-claim""#)
        let usdHourlyClaim = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/USD 20 per hour")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"usd-hourly-claim""#)
        let dollarsWeeklyClaim = trustedEconomicsRowJSON()
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/earn 20 dollars every week")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"dollars-weekly-claim""#)
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [
                pathDisplay,
                bidiModel,
                formatControlDisplay,
                rewardClaim,
                monthlyPayoutClaim,
                dailyPayoutClaim,
                usdHourlyClaim,
                dollarsWeeklyClaim,
            ]).utf8)
        )

        let rows = try document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
        XCTAssertTrue(rows.isEmpty)
    }

    func testCatalogEconomicsSuppressesNonTrustedSwitchActionsAndRawDisabledReasons() throws {
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let json = trustedEconomicsRowJSON(switchAction: action, economicsState: "fallback")
            .replacingOccurrences(of: #""disabled_reason":null"#, with: #""disabled_reason":"/private/tmp/provider-token will pay daily""#)
        let document = try JSONDecoder().decode(
            MalibuModelCatalogEconomicsDocument.self,
            from: Data(catalogEconomicsJSON(rows: [json]).utf8)
        )

        let row = try XCTUnwrap(document.validated(now: ModelTestTimestamp.date)
            .rowsForMalibu(currentModelID: "other/model", warmSwapAvailable: true)
            .first)
        XCTAssertEqual(row.category, .blocked)
        XCTAssertEqual(row.action, .none)
        XCTAssertFalse((row.blockReason ?? "").contains("/private"))
        XCTAssertFalse((row.blockReason ?? "").localizedCaseInsensitiveContains("will pay"))
    }

    @MainActor
    func testRefreshUsesCatalogEconomicsProjectionWhenAdvertised() async throws {
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: {
                    let timestamp = Self.recentTimestamp()
                    return managedCatalogEconomicsJSON(rows: [
                        localOnlyBYOMRowJSON(),
                        trustedEconomicsRowJSON(
                            rateCardGeneratedAt: timestamp,
                            stateObservedAt: timestamp
                        ),
                    ], generatedAt: timestamp)
                }(),
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.catalog.\(UUID().uuidString)")!
        )

        await store.refresh(currentModelID: "other/model", peer: localPeer())

        XCTAssertEqual(cli.invocations.first?.prefix(3), ["models", "catalog-economics", "--json"])
        XCTAssertEqual(store.rows.map(\.displayID), ["mlx-community/Qwen3-8B-4bit"])
        XCTAssertEqual(store.rows.first?.category, .networkCatalog)
        XCTAssertFalse(store.statusLine.localizedCaseInsensitiveContains("discovery failure"))
    }

    @MainActor
    func testRefreshDoesNotSpawnLegacyListWhenCatalogReadCapabilityMissing() async throws {
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: """
                {"schema_version":"models_list.v1","generated_at":"2026-08-08T00:00:00Z","source":"control_socket","warm_swap_available":true,"current_model_id":"org/current","rows":[{"model_id":"org/current","display_id":"org/current","action_model_id":"org/current","state":"warm","weights_present_locally":true,"source":"status_response","fit":"fits","estimated_gb":4.0}]}
                """,
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.legacy.\(UUID().uuidString)")!
        )

        await store.refresh(currentModelID: "org/current", peer: peer(for: MalibuModelCapabilityManifest.readySwitch))

        XCTAssertTrue(cli.invocations.isEmpty)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.currentModelID, "org/current")
        XCTAssertEqual(store.listState, .viewOnly)
    }

    @MainActor
    func testLegacyFallbackCancelsPreviousCatalogProjectionExpiry() async throws {
        let expiringAt = Self.timestamp(offset: -299.8)
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [trustedEconomicsRowJSON(
                        rateCardGeneratedAt: expiringAt,
                        stateObservedAt: expiringAt
                    )],
                    generatedAt: expiringAt
                ),
                stderr: ""
            ),
            ModelCLIResult(
                exitCode: 0,
                stdout: """
                {"schema_version":"models_list.v1","generated_at":"2026-08-08T00:00:00Z","source":"control_socket","warm_swap_available":true,"current_model_id":"org/current","rows":[{"model_id":"org/current","display_id":"org/current","action_model_id":"org/current","state":"warm","weights_present_locally":true,"source":"status_response","fit":"fits","estimated_gb":4.0}]}
                """,
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.expiry.\(UUID().uuidString)")!
        )

        await store.refresh(currentModelID: "other/model", peer: localPeer())
        XCTAssertFalse(store.rows.isEmpty)
        await store.refresh(currentModelID: "org/current", peer: peer(for: MalibuModelCapabilityManifest.readySwitch))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.currentModelID, "org/current")
        XCTAssertEqual(store.listState, .viewOnly)
        XCTAssertFalse(store.catalogProjectionRetryAvailable)
    }

    @MainActor
    func testEqualCatalogProjectionSequenceIsIgnored() async throws {
        let firstTimestamp = Self.recentTimestamp()
        let secondTimestamp = Self.recentTimestamp()
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [trustedEconomicsRowJSON(
                        rateCardGeneratedAt: firstTimestamp,
                        stateObservedAt: firstTimestamp
                    )],
                    generatedAt: firstTimestamp,
                    projectionSequence: 1
                ),
                stderr: ""
            ),
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [
                        trustedEconomicsRowJSON(
                            rateCardGeneratedAt: secondTimestamp,
                            stateObservedAt: secondTimestamp
                        )
                            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/Other-Trusted-4bit")
                    ],
                    generatedAt: secondTimestamp,
                    projectionSequence: 1
                ),
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.equalSequence.\(UUID().uuidString)")!
        )
        let peer = localPeer()

        await store.refresh(currentModelID: "other/model", peer: peer)
        await store.refresh(currentModelID: "other/model", peer: peer)

        XCTAssertEqual(store.rows.map(\.displayID), ["mlx-community/Qwen3-8B-4bit"])
        XCTAssertEqual(store.listState, .viewOnly)
    }

    @MainActor
    func testRefreshFallsBackToStaticCurrentStateWhenProjectionFails() async throws {
        let cli = FakeModelCLI(results: [
            ModelCLIResult(exitCode: 1, stdout: "", stderr: "boom"),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.failure.\(UUID().uuidString)")!
        )

        await store.refresh(currentModelID: "org/current", peer: localPeer())

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.currentModelID, "org/current")
        XCTAssertEqual(store.listState, .unavailable)
        XCTAssertTrue(store.catalogProjectionRetryAvailable)
        XCTAssertTrue(store.statusLine.contains("could not be fully checked"))
    }

    @MainActor
    func testCatalogProjectionExpiryClearsRowsDuringRuntimeConflict() async throws {
        let expiringAt = Self.timestamp(offset: -299.8)
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let transactionID = "c23c5d4c-3e4f-47ac-b72d-7f8f172747a0"
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [trustedEconomicsRowJSON(
                        switchAction: action,
                        rateCardGeneratedAt: expiringAt,
                        stateObservedAt: expiringAt
                    )],
                    generatedAt: expiringAt
                ),
                stderr: ""
            ),
            ModelCLIResult(
                exitCode: 0,
                stdout: """
                {"schema_version":"model_switch_event.v1","type":"accepted","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"requested","elapsed_ms":1,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                {"schema_version":"model_switch_event.v1","type":"terminal","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"loaded","elapsed_ms":2,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                """,
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.expiryConflict.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])

        await store.refresh(currentModelID: "other/model", peer: peer)
        let row = try XCTUnwrap(store.rows.first)
        await store.switchTo(row)
        await store.refresh(currentModelID: "unexpected/model", peer: peer)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
        if case .runtimeConflict(expected: "candidate-qwen", observed: "unexpected/model") = store.operation {
        } else {
            XCTFail("Expected runtime conflict to remain after projection expiry, got \(store.operation)")
        }
        XCTAssertTrue(store.statusLine.contains("projection_unavailable"))
    }

    @MainActor
    func testCatalogProjectionExpiryClearsRowsDuringReconciliation() async throws {
        let expiringAt = Self.timestamp(offset: -299.8)
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let transactionID = "d575f262-7252-449a-bfda-a16fa7f1ac7d"
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [trustedEconomicsRowJSON(
                        switchAction: action,
                        rateCardGeneratedAt: expiringAt,
                        stateObservedAt: expiringAt
                    )],
                    generatedAt: expiringAt
                ),
                stderr: ""
            ),
            ModelCLIResult(
                exitCode: 0,
                stdout: """
                {"schema_version":"model_switch_event.v1","type":"accepted","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"requested","elapsed_ms":1,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                {"schema_version":"model_switch_event.v1","type":"terminal","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"loaded","elapsed_ms":2,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                """,
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.expiryReconciling.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])

        await store.refresh(currentModelID: "other/model", peer: peer)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.action, .switchModel)
        await store.switchTo(row)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
        if case .reconciling(target: "candidate-qwen") = store.operation {
        } else {
            XCTFail("Expected reconciliation to remain after projection expiry, got \(store.operation)")
        }
        XCTAssertTrue(store.statusLine.contains("projection_unavailable"))
    }

    @MainActor
    func testCatalogProjectionExpiryClearsRowsDuringStalledSwitch() async throws {
        let expiringAt = Self.timestamp(offset: -299.8)
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let cli = FakeModelCLI(
            results: [
                ModelCLIResult(
                    exitCode: 0,
                    stdout: managedCatalogEconomicsJSON(
                        rows: [trustedEconomicsRowJSON(
                            switchAction: action,
                            rateCardGeneratedAt: expiringAt,
                            stateObservedAt: expiringAt
                        )],
                        generatedAt: expiringAt
                    ),
                    stderr: ""
                ),
                ModelCLIResult(exitCode: 0, stdout: "", stderr: ""),
            ],
            returnDelaysNanoseconds: [nil, 2_000_000_000]
        )
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.expirySwitching.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])

        await store.refresh(currentModelID: "other/model", peer: peer)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.action, .switchModel)
        let switchTask = Task { await store.switchTo(row) }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
        if case .switching(target: "candidate-qwen", phase: "requested", elapsedMS: 0) = store.operation {
        } else {
            XCTFail("Expected switching operation to remain after projection expiry, got \(store.operation)")
        }
        XCTAssertTrue(store.statusLine.contains("projection_unavailable"))

        switchTask.cancel()
        await switchTask.value
    }

    @MainActor
    func testCatalogProjectionExpiryClearsRowsAfterOperationFailure() async throws {
        let expiringAt = Self.timestamp(offset: -299.8)
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [trustedEconomicsRowJSON(
                        switchAction: action,
                        rateCardGeneratedAt: expiringAt,
                        stateObservedAt: expiringAt
                    )],
                    generatedAt: expiringAt
                ),
                stderr: ""
            ),
            ModelCLIResult(exitCode: 1, stdout: "", stderr: "switch failed"),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.expiryFailure.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])

        await store.refresh(currentModelID: "other/model", peer: peer)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.action, .switchModel)
        await store.switchTo(row)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
        XCTAssertTrue(store.catalogProjectionRetryAvailable)
        XCTAssertTrue(store.statusLine.contains("projection_unavailable"))
    }

    @MainActor
    func testCatalogEconomicsSwitchReconciliationSuspendsCatalogActionsUntilRefresh() async throws {
        let action = availableActionJSON(kind: "switch_model", timeout: 20)
        let transactionID = "c23c5d4c-3e4f-47ac-b72d-7f8f172747a0"
        let timestamp = Self.recentTimestamp()
        let unsupportedRow = trustedEconomicsRowJSON(
            rateCardGeneratedAt: timestamp,
            stateObservedAt: timestamp
        )
            .replacingOccurrences(of: #""runtime_state":"catalog""#, with: #""runtime_state":"future_ready""#)
            .replacingOccurrences(of: "mlx-community/Qwen3-8B-4bit", with: "mlx-community/Unsupported-4bit")
            .replacingOccurrences(of: #""action_model_id":"candidate-qwen""#, with: #""action_model_id":"unsupported-candidate""#)
        let cli = FakeModelCLI(results: [
            ModelCLIResult(
                exitCode: 0,
                stdout: managedCatalogEconomicsJSON(
                    rows: [
                        trustedEconomicsRowJSON(
                            switchAction: action,
                            rateCardGeneratedAt: timestamp,
                            stateObservedAt: timestamp
                        ),
                        unsupportedRow,
                    ],
                    generatedAt: timestamp
                ),
                stderr: ""
            ),
            ModelCLIResult(
                exitCode: 0,
                stdout: """
                {"schema_version":"model_switch_event.v1","type":"accepted","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"requested","elapsed_ms":1,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                {"schema_version":"model_switch_event.v1","type":"terminal","transaction_id":"\(transactionID)","from_model_id":"other/model","target_model_id":"candidate-qwen","phase":"loaded","elapsed_ms":2,"cancellable":false,"reason":null,"cooldown_seconds_remaining":null}
                """,
                stderr: ""
            ),
        ])
        let store = ModelManagementStore(
            cli: cli,
            paths: testProviderPaths(),
            defaults: UserDefaults(suiteName: "ModelManagementTests.switch.\(UUID().uuidString)")!
        )
        let peer = peer(for: [
            MalibuModelCapabilityManifest.catalogEconomics,
            MalibuModelCapabilityManifest.readySwitch,
        ])

        await store.refresh(currentModelID: "other/model", peer: peer)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.action, .switchModel)
        await store.switchTo(row)
        await store.refresh(currentModelID: "candidate-qwen", peer: peer)

        XCTAssertEqual(store.rows.first?.category, .current)
        XCTAssertEqual(store.rows.first?.action, MalibuModelRow.Action.none)
        let unsupported = try XCTUnwrap(store.rows.first(where: { $0.displayID == "mlx-community/Unsupported-4bit" }))
        XCTAssertEqual(unsupported.category, .blocked)
        XCTAssertEqual(unsupported.action, MalibuModelRow.Action.none)
    }

    func testCatalogEconomicsDisplayCopyAvoidsForbiddenRewardClaims() {
        let strings = [
            "Catalog rates are informational. Final provider credit depends on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and active policy status.",
            "Provider share rate: completion $0.36 per 1M tokens.",
            "Provider share rate: prompt $0.18 per 1M tokens.",
            "No provider credit yet; catalog and receipt checks are still required.",
        ].joined(separator: "\n").lowercased()
        for forbidden in ["guaranteed", "daily revenue", "hourly pay", "will pay", "estimated daily", "up to", "higher-paying"] {
            XCTAssertFalse(strings.contains(forbidden), forbidden)
        }
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
            // SPEC-023 §3.7.6 rule 6: the artifact-feed classes decode and never
            // block, even the ones named `_integrity_failure` / `_update_required`.
            "catalog_artifact_feed_fallback_used",
            "catalog_artifact_feed_integrity_failure",
            "catalog_artifact_feed_update_required",
            "catalog_artifact_feed_stale",
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

    // Deterministic app/CLI integration fixtures; these do not qualify real MLX execution.
    func testLocalProjectionRequiresExplicitCapabilityNegotiation() throws {
        let data = Data(localProjection().utf8)
        let document = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: data)
        XCTAssertThrowsError(try document.validated())
        let accepted = try document.validated(localActivationNegotiated: true)
        let row = try XCTUnwrap(accepted.rowsForMalibu(currentModelID: nil, warmSwapAvailable: true).first)
        XCTAssertEqual(row.action, .prepare)
        XCTAssertTrue(row.localActivation)
        XCTAssertEqual(row.catalogModelKey, "local-candidate")
        XCTAssertNil(row.providerPromptPayoutUSDPerMillionTokens)
        XCTAssertNil(row.providerCompletionPayoutUSDPerMillionTokens)
        XCTAssertNil(row.demandRank)
        XCTAssertTrue(row.economicsRateLines.isEmpty)
        XCTAssertNil(row.economicsAccessibilityLabel)
    }

    func testLocalProjectionRejectsInjectedDemandAndUnconfirmedPreparation() throws {
        for json in [
            localProjection().replacingOccurrences(of: "\"demand_rank\":null", with: "\"demand_rank\":1"),
            localProjection().replacingOccurrences(of: "\"requires_confirmation\":true", with: "\"requires_confirmation\":false"),
            localProjection().replacingOccurrences(of: "\"admission_state_missing\"", with: "\"feed_signature_invalid\""),
            localProjection().replacingOccurrences(of: "\"action_model_id\":\"local-candidate\"", with: "\"action_model_id\":null")
        ] {
            let document = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: Data(json.utf8)).validated(localActivationNegotiated: true)
            XCTAssertFalse(document.rowsForMalibu(currentModelID: nil, warmSwapAvailable: true).contains { $0.catalogTransaction != nil })
        }
    }

    func testCatalogTransactionRejectsMalformedEventsAndForeignTargets() throws {
        let original = transactionEvent(state: "running", sequence: 1)
        for json in [
            original.replacingOccurrences(of: "\"running\"", with: "\"unknown\""),
            original.replacingOccurrences(of: "\"heartbeat\":true", with: "\"heartbeat\":false"),
            original.replacingOccurrences(of: "\"progress\":", with: "\"unknown\":null,\"progress\":"),
            original.replacingOccurrences(of: "\"prepare_model\"", with: "\"delete_all\"")
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(MalibuCatalogTransactionEvent.self, from: Data(json.utf8)))
        }
        let event = try JSONDecoder().decode(MalibuCatalogTransactionEvent.self, from: Data(original.utf8))
        var transcript = MalibuCatalogTransactionTranscript()
        XCTAssertThrowsError(try transcript.consume(event, id: "other", kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertThrowsError(try transcript.consume(event, id: transactionID, kind: "prepare_model", modelKey: "other", generation: transactionID))
    }

    func testCatalogTransactionReplayCannotRewriteTerminalOrGoBackward() throws {
        var transcript = MalibuCatalogTransactionTranscript()
        func event(_ state: String, _ sequence: UInt64) throws -> MalibuCatalogTransactionEvent {
            try JSONDecoder().decode(MalibuCatalogTransactionEvent.self, from: Data(transactionEvent(state: state, sequence: sequence).utf8))
        }
        XCTAssertTrue(try transcript.consume(event("running", 2), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertFalse(try transcript.consume(event("running", 2), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertThrowsError(try transcript.consume(event("running", 1), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertTrue(try transcript.consume(event("succeeded", 3), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertThrowsError(try transcript.consume(event("failed", 3), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
        XCTAssertThrowsError(try transcript.consume(event("running", 4), id: transactionID, kind: "prepare_model", modelKey: "local-candidate", generation: transactionID))
    }

    @MainActor
    func testPreparedActionDispatchRequiresConfirmationAndFreshProjectionBeforeSuccess() async throws {
        let terminal = transactionEvent(state: "succeeded", sequence: 2)
        let cli = FakeModelCLI(results: [ok(localProjection()), ok(terminal), ok(quickProjection(localProjection(prepared: true, sequence: 2))), ok(localProjection(prepared: true, sequence: 3))])
        let control = FakeModelCLI(results: [ok(terminal)])
        let defaults = UserDefaults(suiteName: "build1-app-\(UUID())")!
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: defaults)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertTrue(store.catalogConfirmation(for: row).contains("size is unavailable"))
        XCTAssertTrue(store.catalogConfirmation(for: row).contains("Verified signed MacProvider catalog"))
        await store.performCatalogAction(row, confirmed: false)
        XCTAssertEqual(cli.invocations.count, 1)
        await store.performCatalogAction(row, confirmed: true)
        XCTAssertEqual(Array(cli.invocations[1].prefix(8)), ["models", "prepare", "local-candidate", "--transaction-id", transactionID, "--confirm", "--operation-generation", transactionID])
        XCTAssertTrue(cli.invocations[0].contains("--local-activation"))
        XCTAssertEqual(Array(control.invocations[0].prefix(8)), ["models", "transaction", "status", transactionID, "--model", "local-candidate", "--expected-kind", "prepare_model"])
        XCTAssertNil(store.pendingCatalogTransaction)
        XCTAssertEqual(store.operation, .idle)
        XCTAssertEqual(store.currentModelID, "incumbent/model")
        XCTAssertTrue(store.rows[0].weightsPresentLocally)
    }

    @MainActor
    func testTerminalWithoutFreshProjectionRemainsPendingAndRecoversLater() async throws {
        let terminal = transactionEvent(state: "succeeded", sequence: 2)
        let cli = FakeModelCLI(results: [ok(localProjection()), ok(terminal), ModelCLIResult(exitCode: 1, stdout: "", stderr: "unavailable"), ok(quickProjection(localProjection(prepared: true, sequence: 2))), ok(localProjection(prepared: true, sequence: 3))])
        let control = FakeModelCLI(results: [ok(terminal), ok(terminal)])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "build1-app-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        await store.performCatalogAction(try XCTUnwrap(store.rows.first), confirmed: true)
        XCTAssertNotNil(store.pendingCatalogTransaction)
        XCTAssertEqual(store.operation, .catalogTransaction)
        XCTAssertFalse(store.canPerformModelAction)
        await store.reconcileCatalogTransaction()
        XCTAssertNil(store.pendingCatalogTransaction)
        XCTAssertEqual(store.operation, .idle)
    }

    @MainActor
    func testRestartReconcilesPersistedTransactionAndDisclosesLateCancellation() async throws {
        let defaults = UserDefaults(suiteName: "build1-app-\(UUID())")!
        var pending = MalibuPendingCatalogTransaction(id: transactionID, target: "local-candidate", modelKey: "local-candidate", kind: "prepare_model", timeoutSeconds: 1800, startedAt: Date(), operationGeneration: transactionID, cancelRequested: true)
        let paths = testProviderPaths()
        pending.pin = try await FakeModelCLI(results: []).authorizeCatalog(pending, contextDigest: String(repeating: "a", count: 64), peer: localPeer(), paths: paths)
        try MalibuTransactionFiles.save(pending, paths: paths)
        let cli = FakeModelCLI(results: [ok(quickProjection(localProjection(prepared: true))), ok(localProjection(prepared: true, sequence: 2))])
        let control = FakeModelCLI(results: [ok(transactionEvent(state: "succeeded", sequence: 2))])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: paths, defaults: defaults)
        XCTAssertEqual(store.operation, .catalogTransaction)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        XCTAssertNil(store.pendingCatalogTransaction)
        XCTAssertTrue(store.statusLine.contains("after commit"))
        XCTAssertEqual(cli.invocations.count, 2)
        XCTAssertEqual(control.invocations[0][2], "status")
    }

    @MainActor
    func testDelayedTransactionKeepsCancellationAndUsesCLIControl() async throws {
        let defaults = UserDefaults(suiteName: "build1-app-\(UUID())")!
        var pending = MalibuPendingCatalogTransaction(id: transactionID, target: "local-candidate", modelKey: "local-candidate", kind: "prepare_model", timeoutSeconds: 1800, startedAt: Date(), operationGeneration: transactionID)
        let paths = testProviderPaths()
        pending.pin = try await FakeModelCLI(results: []).authorizeCatalog(pending, contextDigest: String(repeating: "a", count: 64), peer: localPeer(), paths: paths)
        try MalibuTransactionFiles.save(pending, paths: paths)
        let control = FakeModelCLI(results: [ok(transactionEvent(state: "cancel_requested", sequence: 1))])
        let store = ModelManagementStore(cli: FakeModelCLI(results: []), transactionControlCLI: control, paths: paths, defaults: defaults)
        store.updateCatalogTransactionDelay(now: Date().addingTimeInterval(31))
        XCTAssertTrue(store.catalogTransactionDelayed)
        XCTAssertNotNil(store.pendingCatalogTransaction)
        await store.requestCatalogCancellation()
        XCTAssertEqual(Array(control.invocations[0].prefix(8)), ["models", "transaction", "cancel", transactionID, "--model", "local-candidate", "--expected-kind", "prepare_model"])
        XCTAssertTrue(store.catalogTransactionCancelRequested)
        XCTAssertNotNil(store.pendingCatalogTransaction)
    }

    @MainActor
    func testMeasuredLocalResultAdoptsOriginalEvidenceAndOffersWithoutEconomicsDisplay() async throws {
        let terminal = transactionEvent(state: "succeeded", sequence: 2, kind: "evaluate_model")
        let target = "mlx-community/Qwen3-8B-4bit"
        let initial = localProjection(prepared: true, kind: "evaluate_model")
            .replacingOccurrences(of: "\"model_key\":\"local-candidate\"", with: "\"model_key\":\"qwen3-8b\"")
            .replacingOccurrences(of: "local-candidate", with: target)
        let refreshed = localProjection(prepared: true, sequence: 2, kind: "evaluate_model", adoption: true)
            .replacingOccurrences(of: "\"model_key\":\"local-candidate\"", with: "\"model_key\":\"qwen3-8b\"")
            .replacingOccurrences(of: "local-candidate", with: target)
        let events = terminal.replacingOccurrences(of: "local-candidate", with: "qwen3-8b")
        let recommendation = localRecommendationJSON()
        let adoption = """
        {"schema_version":"model_adoption_event.v1","type":"accepted","transaction_id":"a13c5d4c-3e4f-47ac-b72d-7f8f172747a0","target_model_id":"qwen3-8b","from_model_id":"incumbent/model","phase":null,"reason":null,"rollback_state":null}
        {"schema_version":"model_adoption_event.v1","type":"completed","transaction_id":"a13c5d4c-3e4f-47ac-b72d-7f8f172747a0","target_model_id":"qwen3-8b","from_model_id":"incumbent/model","phase":null,"reason":null,"rollback_state":null,"config_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        """
        func currentProjection(_ sequence: UInt64) -> String {
            localProjection(prepared: true, sequence: sequence)
                .replacingOccurrences(of: "\"model_key\":\"local-candidate\"", with: "\"model_key\":\"qwen3-8b\"")
                .replacingOccurrences(of: "local-candidate", with: target)
                .replacingOccurrences(of: "\"is_current\":false", with: "\"is_current\":true")
                .replacingOccurrences(of: "\"state\":\"local_only\"", with: sequence >= 4 ? "\"state\":\"offer_submitted\"" : "\"state\":\"local_only\"")
                .replacingOccurrences(of: "\"source\":\"local_default\"", with: sequence >= 4 ? "\"source\":\"coordinator\"" : "\"source\":\"local_default\"")
        }
        func sequence(_ json: String, _ value: UInt64) -> String {
            var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            object["projection_sequence"] = value
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let cli = FakeModelCLI(results: [ok(quickProjection(initial)), ok(sequence(initial, 2)), ok(events),
            ok(quickProjection(sequence(refreshed, 3))), ok(sequence(refreshed, 4)), ok(adoption),
            ok("{}"), ok(quickProjection(currentProjection(5))), ok("{}"), ok(quickProjection(currentProjection(6))),
            ok(currentProjection(7)), ok("{}"), ok(quickProjection(currentProjection(8)))])
        let control = FakeModelCLI(results: [ok(events), ok(recommendation)])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "build1-app-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        await store.verifyLocalFiles(try XCTUnwrap(store.rows.first))
        await store.performCatalogAction(try XCTUnwrap(store.rows.first), confirmed: true)
        XCTAssertTrue(cli.invocations.contains { $0[1] == "recommend-prepared" })
        XCTAssertEqual(control.invocations[1][2], "result")
        XCTAssertTrue(store.recommendationIsLocalActivation)
        XCTAssertNotNil(store.recommendation)
        XCTAssertTrue(try XCTUnwrap(store.rows.first).economicsRateLines.isEmpty)
        XCTAssertTrue(store.canAdoptRecommendation)
        await store.adoptRecommendation()
        let adoptionIndex = try XCTUnwrap(cli.invocations.firstIndex { $0[1] == "adopt-recommendation" })
        XCTAssertEqual(cli.stdinPayloads[adoptionIndex], Data((recommendation + "\n").utf8))
        XCTAssertEqual(store.operation, .reconciling(target: "qwen3-8b"))
        await store.refresh(currentModelID: "qwen3-8b", peer: localPeer())
        XCTAssertEqual(store.operation, .idle)
        XCTAssertEqual(store.currentModelID, "qwen3-8b")
        var activated = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(activated.category, .current)
        let before = cli.invocations.count
        await store.requestAdmission(for: activated, confirmed: false)
        XCTAssertEqual(cli.invocations.count, before)
        await store.requestAdmission(for: activated, confirmed: true)
        XCTAssertTrue(cli.invocations.contains { Array($0.prefix(5)) == ["models", "offer", target, "--yes", "--json"] })
        activated = try XCTUnwrap(store.rows.first)
        await store.refreshAdmission(for: activated)
        XCTAssertTrue(cli.invocations.contains { Array($0.prefix(5)) == ["models", "admission", "status", target, "--json"] })
        await store.verifyLocalFiles(try XCTUnwrap(store.rows.first))
        activated = try XCTUnwrap(store.rows.first)
        await store.requestAdmission(for: activated, confirmed: true, retry: true)
        XCTAssertTrue(cli.invocations.contains { Array($0.prefix(6)) == ["models", "admission", "retry", target, "--yes", "--json"] })
        XCTAssertTrue(try XCTUnwrap(store.rows.first).economicsRateLines.isEmpty)
    }

    @MainActor
    func testProjectionReadTimeoutKeepsPendingTransactionAndAllowsLateRecovery() async throws {
        let terminal = transactionEvent(state: "succeeded", sequence: 2)
        let cli = FakeModelCLI(results: [ok(localProjection()), ok(terminal), ok(quickProjection(localProjection(prepared: true, sequence: 2))), ok(quickProjection(localProjection(prepared: true, sequence: 3))), ok(localProjection(prepared: true, sequence: 4))], returnDelaysNanoseconds: [nil, nil, 100_000_000, nil])
        let control = FakeModelCLI(results: [ok(terminal), ok(terminal)])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, catalogReadTimeoutNanoseconds: 20_000_000, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "build1-app-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        await store.performCatalogAction(try XCTUnwrap(store.rows.first), confirmed: true)
        XCTAssertNotNil(store.pendingCatalogTransaction)
        XCTAssertEqual(store.operation, .catalogTransaction)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(store.pendingCatalogTransaction)
        await store.reconcileCatalogTransaction()
        XCTAssertNil(store.pendingCatalogTransaction)
    }

    @MainActor
    func testPreparedRecommendationRestoresAfterAppRestartThroughResultOnly() async throws {
        let target = "mlx-community/Qwen3-8B-4bit"
        let projection = localProjection(prepared: true, kind: "evaluate_model", adoption: true)
            .replacingOccurrences(of: "\"model_key\":\"local-candidate\"", with: "\"model_key\":\"qwen3-8b\"")
            .replacingOccurrences(of: "local-candidate", with: target)
        let control = FakeModelCLI(results: [ok(localRecommendationJSON())])
        let cli = FakeModelCLI(results: [ok(quickProjection(projection)), ok(projection.replacingOccurrences(of: "\"projection_sequence\":1", with: "\"projection_sequence\":2"))])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "build1-app-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        await store.verifyLocalFiles(try XCTUnwrap(store.rows.first))
        XCTAssertEqual(cli.invocations.count, 2)
        XCTAssertEqual(Array(control.invocations[0].prefix(8)), ["models", "transaction", "result", transactionID, "--model", target, "--expected-kind", "evaluate_model"])
        XCTAssertTrue(store.canAdoptRecommendation)
        XCTAssertTrue(store.recommendationIsLocalActivation)
    }

    @MainActor
    func testCleanupIsTransactionScopedAndDoesNotClaimFreshFeedAuthority() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(localProjection(prepared: true).utf8)) as? [String: Any])
        var action = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(availableActionJSON(kind: "cleanup_staging", timeout: 1800).utf8)) as? [String: Any])
        action["operation_generation"] = transactionID
        object["recoveries"] = [["target_model_id": "removed/model", "model_key": "local-candidate", "action": action]]
        let projection = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let terminal = transactionEvent(state: "succeeded", sequence: 2, kind: "cleanup_staging")
        let cli = FakeModelCLI(results: [ok(quickProjection(projection)), ok(terminal), ok(quickProjection(localProjection(prepared: true, sequence: 2))), ok(localProjection(prepared: true, sequence: 3))])
        let control = FakeModelCLI(results: [ok(terminal)])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "build1-app-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        let recovery = try XCTUnwrap(store.cleanupRecoveries.first)
        XCTAssertEqual(store.rows.first?.action, MalibuModelRow.Action.none)
        XCTAssertTrue(store.cleanupConfirmation(recovery).contains("CLI-owned"))
        XCTAssertFalse(store.cleanupConfirmation(recovery).contains("Verified signed"))
        XCTAssertTrue(store.cleanupConfirmation(recovery).contains("unavailable"))
        await store.performCleanupRecovery(recovery, confirmed: true)
        let command = try XCTUnwrap(cli.invocations.dropFirst().first)
        XCTAssertEqual(Array(command.prefix(6)), ["models", "cleanup-staging", transactionID, "--model", "removed/model", "--confirm"])
        XCTAssertTrue(command.contains("--operation-generation"))
        XCTAssertNil(store.pendingCatalogTransaction)
    }

    func testLocalRecommendationBindsCatalogKeyAndCanonicalTargetWithoutChangingLegacy() throws {
        let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(localRecommendationJSON().utf8))
        XCTAssertThrowsError(try document.validated())
        XCTAssertNoThrow(try document.validated(localActivationTarget: "mlx-community/Qwen3-8B-4bit", localActivationModelKey: "qwen3-8b"))
        XCTAssertThrowsError(try document.validated(localActivationTarget: "wrong/model", localActivationModelKey: "qwen3-8b"))
        XCTAssertThrowsError(try document.validated(localActivationTarget: "mlx-community/Qwen3-8B-4bit", localActivationModelKey: "wrong-key"))
        XCTAssertFalse(document.isActionable)
        XCTAssertTrue(document.isEligibleForLocalActivation)
    }

    func testLocalActivationPermitsAuthenticatedFallbackButBlocksStaleOrSafetyWarnings() throws {
        let baseline = localRecommendationJSON()
        for (warning, eligible) in [("rate_card_fallback_used", true), ("candidate_catalog_fallback_used", true), ("rate_card_stale", false), ("catalog_artifact_feed_integrity_failure", false), ("swap_observed_under_load", false)] {
            let json = baseline.replacingOccurrences(of: #"}],"warnings":[]}"#, with: "}],\"warnings\":[\"\(warning)\"]}")
            let document = try JSONDecoder().decode(MalibuRecommendationDocument.self, from: Data(json.utf8)).validated(localActivationTarget: "mlx-community/Qwen3-8B-4bit", localActivationModelKey: "qwen3-8b")
            XCTAssertEqual(document.isEligibleForLocalActivation, eligible, warning)
            XCTAssertFalse(document.isActionable)
        }
    }

    @MainActor
    func testCancelledTransactionCanReconcileWhenTargetLeavesCatalog() async throws {
        let defaults = UserDefaults(suiteName: "build1-app-\(UUID())")!
        var pending = MalibuPendingCatalogTransaction(id: transactionID, target: "local-candidate", modelKey: "local-candidate", kind: "prepare_model", timeoutSeconds: 1800, startedAt: Date(), operationGeneration: transactionID)
        let paths = testProviderPaths()
        pending.pin = try await FakeModelCLI(results: []).authorizeCatalog(pending, contextDigest: String(repeating: "a", count: 64), peer: localPeer(), paths: paths)
        try MalibuTransactionFiles.save(pending, paths: paths)
        let empty = managedCatalogEconomicsJSON(rows: [], generatedAt: ISO8601DateFormatter().string(from: Date()))
        let store = ModelManagementStore(cli: FakeModelCLI(results: [ok(empty)]), transactionControlCLI: FakeModelCLI(results: [ok(transactionEvent(state: "cancelled", sequence: 2))]), paths: paths, defaults: defaults)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        XCTAssertNil(store.pendingCatalogTransaction)
        XCTAssertEqual(store.operation, .idle)
        XCTAssertTrue(store.statusLine.contains("cancelled"))
        XCTAssertEqual(store.currentModelID, "incumbent/model")
    }

    private func localRecommendationJSON() -> String {
        recommendationJSON()
            .replacingOccurrences(of: "2026-08-09T00:00:00Z", with: ISO8601DateFormatter().string(from: Date()))
            .replacingOccurrences(of: "\"recommended_model\":\"mlx-community/Qwen3-8B-4bit\"", with: "\"recommended_model\":\"qwen3-8b\"")
            .replacingOccurrences(of: "\"model\":\"mlx-community/Qwen3-8B-4bit\"", with: "\"model\":\"qwen3-8b\"")
    }

    func testRecoveryClosedShapeAndGenerationRejectMalformedSelectors() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(localProjection(prepared: true).utf8)) as? [String: Any])
        var action = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(availableActionJSON(kind: "cleanup_staging", timeout: 1800).utf8)) as? [String: Any])
        action["operation_generation"] = transactionID
        let recovery: [String: Any] = ["target_model_id": "removed/model", "model_key": "historic-key", "action": action]
        for mutation in 0..<5 {
            var invalid = recovery
            var invalidAction = action
            if mutation == 0 { invalidAction["operation_generation"] = "invalid" }
            if mutation == 1 { invalidAction["transaction_kind"] = "prepare_model" }
            if mutation == 2 { invalidAction["requires_confirmation"] = false }
            if mutation == 3 { invalid["unknown"] = true }
            invalid["action"] = invalidAction
            object["recoveries"] = mutation == 4 ? [recovery, recovery] : [invalid]
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: data).validated(localActivationNegotiated: true))
        }
        object["recoveries"] = [recovery]
        let valid = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: JSONSerialization.data(withJSONObject: object)).validated(localActivationNegotiated: true)
        let baseline = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: Data(localProjection(prepared: true).utf8)).validated(localActivationNegotiated: true)
        XCTAssertEqual(valid.rowsForMalibu(currentModelID: "local-candidate", warmSwapAvailable: true), baseline.rowsForMalibu(currentModelID: "local-candidate", warmSwapAvailable: true))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalogEconomicsJSON(rows: []).utf8)) as? [String: Any])
        legacy["recoveries"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }

    func testTransactionGenerationCannotCrossCleanupAttempts() throws {
        let event = try JSONDecoder().decode(MalibuCatalogTransactionEvent.self, from: Data(transactionEvent(state: "running", sequence: 19, kind: "cleanup_staging").utf8))
        var transcript = MalibuCatalogTransactionTranscript()
        XCTAssertThrowsError(try transcript.consume(event, id: transactionID, kind: "cleanup_staging", modelKey: "local-candidate", generation: UUID().uuidString.lowercased()))
        XCTAssertTrue(transcript.events.isEmpty)
        XCTAssertTrue(try transcript.consume(event, id: transactionID, kind: "cleanup_staging", modelKey: "local-candidate", generation: transactionID))
    }

    @MainActor
    func testAdmissionTerminalReadAndFreshOfferRemainDistinctFromRetry() async throws {
        for state in ["revoked", "withdrawn", "offer_rejected", "offer_submitted", "sandbox_probe_only", "network_admitted_unsettled", "catalog_priced"] {
            let projection = localProjection(prepared: true)
                .replacingOccurrences(of: "\"state\":\"local_only\"", with: "\"state\":\"\(state)\"")
                .replacingOccurrences(of: "\"source\":\"local_default\"", with: "\"source\":\"coordinator\"")
            let cli = FakeModelCLI(results: [ok(quickProjection(projection)), ok(projection.replacingOccurrences(of: "\"projection_sequence\":1", with: "\"projection_sequence\":2")), .init(exitCode: 1, stdout: "", stderr: "fixture unavailable")])
            let store = ModelManagementStore(cli: cli, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "gate-\(UUID())")!)
            await store.refresh(currentModelID: "local-candidate", peer: localPeer())
            await store.verifyLocalFiles(try XCTUnwrap(store.rows.first))
            let row = try XCTUnwrap(store.rows.first)
            XCTAssertTrue(store.canRefreshAdmission(for: row), state)
            let terminal = ["revoked", "withdrawn", "offer_rejected"].contains(state)
            XCTAssertEqual(store.canRequestAdmission(for: row), terminal, state)
            XCTAssertEqual(store.canRetryAdmission(for: row), !terminal, state)
            await store.refreshAdmission(for: row)
            XCTAssertTrue(store.canRefreshAdmission(for: row), "failed read must remain retryable")
            XCTAssertEqual(Array(cli.invocations.last!.prefix(3)), ["models", "admission", "status"])
        }
    }

    @MainActor
    func testLegacyPendingDoesNotEnableOfflineControlOrNewMutation() async throws {
        let defaults = UserDefaults(suiteName: "legacy-pin-\(UUID())")!
        defaults.set(Data("{}".utf8), forKey: "malibu.model-management.pending-catalog")
        let cli = FakeModelCLI(results: [ok(localProjection())])
        let control = FakeModelCLI(results: [])
        let store = ModelManagementStore(cli: cli, transactionControlCLI: control, paths: testProviderPaths(), defaults: defaults)
        await store.refresh(currentModelID: "incumbent", peer: localPeer())
        XCTAssertTrue(store.catalogPersistenceBlocked)
        XCTAssertFalse(store.canPerformModelAction)
        await store.requestCatalogCancellation()
        XCTAssertTrue(control.invocations.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "malibu.model-management.pending-catalog"))
    }

    @MainActor
    func testPendingFileRejectsSymlinkAndCrossOperationReplacement() async throws {
        let paths = testProviderPaths()
        var pending = MalibuPendingCatalogTransaction(id: transactionID, target: "target", modelKey: "key", kind: "prepare_model", timeoutSeconds: 1800, startedAt: Date(), operationGeneration: transactionID)
        pending.pin = try await FakeModelCLI(results: []).authorizeCatalog(pending, contextDigest: String(repeating: "a", count: 64), peer: localPeer(), paths: paths)
        try MalibuTransactionFiles.save(pending, paths: paths)
        XCTAssertEqual(try MalibuTransactionFiles.load(paths: paths), pending)
        var other = pending
        other.operationGeneration = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try MalibuTransactionFiles.save(other, paths: paths))
        XCTAssertEqual(try MalibuTransactionFiles.load(paths: paths), pending)
        let url = MalibuTransactionFiles.pendingURL(paths)
        let saved = url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: url, to: saved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved)
        XCTAssertThrowsError(try MalibuTransactionFiles.load(paths: paths))
    }

    @MainActor
    func testControlNormalSpawnInheritsLockAndReleasesAfterExit() async throws {
        let paths = testProviderPaths()
        let directory = MalibuTransactionFiles.directory(paths)
        let script = """
        import os, fcntl, sys
        assert os.read(198, 4096) == b'{}'
        fcntl.flock(199, fcntl.LOCK_EX | fcntl.LOCK_NB)
        other = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raise RuntimeError('lock was released at spawn')
        except BlockingIOError:
            pass
        os.close(other)
        print('inherited-lock-verified')
        """
        let result = try await MalibuBoundedCatalogProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, directory.appendingPathComponent("control.lock").path], expectation: Data("{}".utf8), environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], lockDirectory: directory, control: true, timeout: 10, resultDocument: false, onLine: { _ in })
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("inherited-lock-verified"))
        let descriptor = open(directory.appendingPathComponent("control.lock").path, O_RDWR)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }

    @MainActor
    func testControlTimeoutAndOutputOverflowReapChildAndReleaseLock() async throws {
        let paths = testProviderPaths()
        let directory = MalibuTransactionFiles.directory(paths)
        for script in ["trap '' TERM; while :; do :; done", "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; done"] {
            let start = Date()
            do {
                _ = try await MalibuBoundedCatalogProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], expectation: Data("{}".utf8), environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], lockDirectory: directory, control: true, timeout: 0.3, resultDocument: false, onLine: { _ in })
                XCTFail("bounded helper must fail")
            } catch { }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            let descriptor = open(directory.appendingPathComponent("control.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            close(descriptor)
        }
    }

    @MainActor
    func testControlDeadlineDoesNotWaitForDescendantOutputPipe() async throws {
        let paths = testProviderPaths()
        let script = """
        import os, time
        os.read(198, 4096)
        if os.fork() == 0:
            os.close(199)
            os.close(200)
            time.sleep(3)
            os._exit(0)
        os._exit(0)
        """
        let start = Date()
        do {
            _ = try await MalibuBoundedCatalogProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], expectation: Data("{}".utf8), environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], lockDirectory: MalibuTransactionFiles.directory(paths), control: true, timeout: 1.5, resultDocument: false, onLine: { _ in })
            XCTFail("retained pipe must not keep the control alive")
        } catch { }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.4)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    private let transactionID = "c23c5d4c-3e4f-47ac-b72d-7f8f172747a0"
    private func transactionEvent(state: String, sequence: UInt64, kind: String = "prepare_model") -> String {
        let progress = ["running", "cancel_requested"].contains(state) ? #"{"stage_label_key":"preparing","heartbeat":true}"# : "null"
        return """
        {"schema":"model_catalog_transaction_event.v1","transaction_id":"\(transactionID)","transaction_kind":"\(kind)","operation_generation":"\(transactionID)","model_key":"local-candidate","event_sequence":\(sequence),"emitted_at":"2026-09-10T00:00:00Z","state":"\(state)","progress":\(progress),"error_code":null,"warning_code":null}
        """
    }
    @MainActor
    func testCatalogReadCapabilityMatrixNeverProbesUnsupportedCLI() async throws {
        let supported = localPeer()
        let variants = [
            peer(for: MalibuModelCapabilityManifest.catalogEconomics),
            peer(for: MalibuModelCapabilityManifest.readySwitch),
            peer(capabilities: supported.capabilities.subtracting([MalibuModelCapabilityManifest.catalogReadLifecycle]), binaryVersion: "1.8.123"),
            peer(capabilities: supported.capabilities.subtracting([MalibuModelCapabilityManifest.localActivation]), binaryVersion: "1.8.123"),
            peer(capabilities: supported.capabilities, binaryVersion: "1.8.90"), .unavailable
        ]
        for variant in variants {
            let cli = FakeModelCLI(results: [ok(localProjection())])
            let store = ModelManagementStore(cli: cli, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "read-matrix-\(UUID())")!)
            await store.refresh(currentModelID: "incumbent/model", peer: variant)
            XCTAssertTrue(cli.invocations.isEmpty)
            XCTAssertTrue(store.rows.isEmpty)
            XCTAssertFalse(store.canPerformModelAction)
            XCTAssertFalse(store.catalogProjectionRetryAvailable)
            XCTAssertEqual(store.listState, .viewOnly)
        }
        let cli = FakeModelCLI(results: [ok(localProjection())])
        let store = ModelManagementStore(cli: cli, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "read-positive-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: supported)
        XCTAssertEqual(cli.invocations.count, 1)
        XCTAssertTrue(cli.invocations[0].contains("--app-read-request"))
        XCTAssertFalse(cli.invocations[0].contains("--ctl-socket-path"))
    }

    @MainActor
    func testQuickProjectionCannotAdvertiseVerifiedBytes() async throws {
        let cli = FakeModelCLI(results: [ok(localProjection(prepared: true, kind: "evaluate_model"))])
        let store = ModelManagementStore(cli: cli, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "read-truth-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
    }

    func testCatalogReadTranscriptRequiresExactCompleteCurrentProjection() throws {
        let read = MalibuCatalogRead(mode: .verify, target: "local-candidate", modelKey: "local-candidate", context: String(repeating: "a", count: 64))
        let accepted = try readEvent(read, kind: "accepted", sequence: 1, bytes: 0)
        let completed = try readEvent(read, kind: "completed", sequence: 2, bytes: 123, projection: localProjection(prepared: true))
        var transcript = MalibuCatalogReadTranscript()
        try transcript.consume(accepted, read: read)
        try transcript.consume(completed, read: read)
        XCTAssertNotNil(transcript.projection)
        XCTAssertThrowsError(try transcript.consume(completed, read: read))
        for bad in [
            String(decoding: accepted, as: UTF8.self).replacingOccurrences(of: read.id, with: UUID().uuidString.lowercased()),
            String(decoding: accepted, as: UTF8.self).replacingOccurrences(of: "\"event_sequence\":1", with: "\"event_sequence\":2"),
            String(decoding: accepted, as: UTF8.self).replacingOccurrences(of: "\"bytes_completed\":0", with: "\"bytes_completed\":1"),
            String(decoding: accepted, as: UTF8.self).replacingOccurrences(of: "\"schema\":", with: "\"unexpected\":null,\"schema\":"),
            String(decoding: accepted, as: UTF8.self).replacingOccurrences(of: "\"schema\":", with: "\"schema\":\"duplicate\",\"schema\":")
        ] {
            var rejected = MalibuCatalogReadTranscript()
            XCTAssertThrowsError(try rejected.consume(Data(bad.utf8), read: read))
        }
        var incomplete = MalibuCatalogReadTranscript()
        try incomplete.consume(accepted, read: read)
        XCTAssertThrowsError(try incomplete.consume(readEvent(read, kind: "completed", sequence: 2, bytes: 10, projection: quickProjection(localProjection(prepared: true))), read: read))
    }

    @MainActor
    func testOwnedReadTimeoutRetainsSlotUntilExactTermIgnoringChildIsReaped() async throws {
        let executable = try compileReadFixture("signal(SIGTERM,SIG_IGN); for (;;) pause();")
        let paths = testProviderPaths(), owner = ReadFixtureChild(), runner = MalibuCatalogReadRunner()
        do {
            _ = try await runner.run(read: .init(mode: .quick), paths: paths, timeout: 0.15,
                resolve: { executable }, onSpawn: { _, pid in owner.set(pid) }, progress: { _ in })
            XCTFail("The real child must time out")
        } catch {}
        XCTAssertTrue(runner.isBusy)
        let pid = owner.get()
        XCTAssertGreaterThan(pid, 0)
        XCTAssertThrowsError(try MalibuCatalogReadRunner.openLock(paths: paths))
        do {
            _ = try await runner.run(read: .init(mode: .quick), paths: paths, resolve: { executable }, progress: { _ in })
            XCTFail("Replacement must not overlap")
        } catch {}
        for _ in 0..<100 where runner.isBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(runner.isBusy)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let lock = try MalibuCatalogReadRunner.openLock(paths: paths); close(lock)
    }

    @MainActor
    func testOwnedVerificationContinuesMeasuredProgressBeyondTenSeconds() async throws {
        let read = MalibuCatalogRead(mode: .verify, target: "local-candidate", modelKey: "local-candidate", context: String(repeating: "a", count: 64))
        var body = "puts(\(cString(try readEvent(read, kind: "accepted", sequence: 1, bytes: 0)))); fflush(stdout);\n"
        for index in 1...20 {
            body += "usleep(1000000); puts(\(cString(try readEvent(read, kind: "progress", sequence: UInt64(index + 1), bytes: UInt64(index))))); fflush(stdout);\n"
        }
        body += "puts(\(cString(try readEvent(read, kind: "completed", sequence: 22, bytes: 20, projection: localProjection(prepared: true))))); fflush(stdout); return 0;"
        let executable = try compileReadFixture(body), runner = MalibuCatalogReadRunner(), owner = ReadFixtureChild()
        let start = Date()
        var updates: [UInt64] = []
        let result = try await runner.run(read: read, paths: testProviderPaths(), timeout: 30,
            resolve: { executable }, onSpawn: { _, pid in owner.set(pid) }, progress: { updates.append($0.bytes) })
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 20)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(updates.max(), 20)
        XCTAssertFalse(runner.isBusy)
        XCTAssertTrue(result.stdout.contains("verified"))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(owner.get(), &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testLocalVerificationCannotGrantAuthorityToIncompleteOrInvalidRows() throws {
        let verified = localProjection(prepared: true, kind: "evaluate_model")
        let document = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: Data(verified.utf8)).validated(localActivationNegotiated: true)
        XCTAssertTrue(document.hasVerifiedLocalTarget("local-candidate", modelKey: "local-candidate"))
        for state in ["not_applicable", "missing", "unverified", "incomplete", "invalid"] {
            let bad = verified.replacingOccurrences(of: "\"state\":\"verified\"", with: "\"state\":\"\(state)\"")
            let rejected = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: Data(bad.utf8)).validated(localActivationNegotiated: true)
            XCTAssertFalse(rejected.hasVerifiedLocalTarget("local-candidate", modelKey: "local-candidate"))
            XCTAssertTrue(rejected.rowsForMalibu(currentModelID: nil, warmSwapAvailable: true).allSatisfy { $0.action == .none })
        }
        let read = MalibuCatalogRead(mode: .verify, target: "local-candidate", modelKey: "local-candidate", context: String(repeating: "a", count: 64))
        for invalid in [verified.replacingOccurrences(of: "\"fit\":\"fits\"", with: "\"fit\":\"future_fit\""),
                        verified.replacingOccurrences(of: "\"model_key\":\"local-candidate\"", with: "\"model_key\":\"other-key\"")] {
            var transcript = MalibuCatalogReadTranscript()
            try transcript.consume(readEvent(read, kind: "accepted", sequence: 1, bytes: 0), read: read)
            XCTAssertThrowsError(try transcript.consume(readEvent(read, kind: "completed", sequence: 2, bytes: 1, projection: invalid), read: read))
        }
        for state in ["unverified", "incomplete"] {
            let honest = quickProjection(verified).replacingOccurrences(of: "\"state\":\"unverified\"", with: "\"state\":\"\(state)\"")
            let rows = try JSONDecoder().decode(MalibuModelCatalogEconomicsDocument.self, from: Data(honest.utf8)).validated(localActivationNegotiated: true).rowsForMalibu(currentModelID: nil, warmSwapAvailable: true)
            let row = try XCTUnwrap(rows.first)
            XCTAssertTrue(row.needsLocalVerification)
            XCTAssertEqual(row.blockReason, "Local files need verification")
            XCTAssertFalse(row.weightsPresentLocally)
            XCTAssertNil(row.catalogTransaction)
        }
    }

    func testCatalogReadLivenessSeparatesHeartbeatFromByteProgress() {
        let second: UInt64 = 1_000_000_000
        var state = MalibuCatalogReadLiveness(started: 0)
        XCTAssertFalse(state.expired(now: 10 * second - 1))
        XCTAssertTrue(state.expired(now: 10 * second))
        state.observe(bytes: 0, now: second)
        XCTAssertFalse(state.expired(now: 16 * second - 1))
        XCTAssertTrue(state.expired(now: 16 * second))
        state.observe(bytes: 1, now: 2 * second)
        for time in stride(from: UInt64(5), through: 60, by: 5) {
            state.observe(bytes: 1, now: time * second)
        }
        XCTAssertFalse(state.expired(now: 62 * second - 1))
        XCTAssertTrue(state.expired(now: 62 * second))
        state.observe(bytes: 2, now: 62 * second)
        XCTAssertFalse(state.expired(now: 62 * second))
    }

    @MainActor
    func testAbandonedReadPreflightNeverSpawnsOrReleasesSlotEarly() async throws {
        let executable = try compileReadFixture("return 0;")
        let runner = MalibuCatalogReadRunner(), child = ReadFixtureChild(), paths = testProviderPaths()
        do {
            _ = try await runner.run(read: .init(mode: .quick), paths: paths, timeout: 0.03,
                resolve: { usleep(250_000); return executable }, onSpawn: { _, pid in child.set(pid) }, progress: { _ in XCTFail("late callback") })
            XCTFail("deadline must abandon preflight")
        } catch {}
        XCTAssertTrue(runner.isBusy)
        XCTAssertEqual(child.get(), 0)
        for _ in 0..<30 where runner.isBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(runner.isBusy)
        XCTAssertEqual(child.get(), 0)
        let lease = try MalibuCatalogReadRunner.openLock(paths: paths); close(lease)
    }

    @MainActor
    func testOwnedQuickReadDefaultDeadlineRejectsLateValidProjection() async throws {
        let executable = try compileReadFixture("usleep(11000000); puts(\(cString(Data(localProjection().utf8)))); return 0;")
        let cli = OwnedCatalogFixtureCLI(executable: executable)
        let store = ModelManagementStore(cli: cli, paths: testProviderPaths(), defaults: UserDefaults(suiteName: "read-late-\(UUID())")!)
        let start = Date()
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 9.9)
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
        for _ in 0..<100 where cli.catalogReadIsBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(cli.catalogReadIsBusy)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.listState, .unavailable)
        XCTAssertEqual(store.currentModelID, "incumbent/model")
        XCTAssertEqual(cli.spawned.get().count, 1)
    }

    @MainActor
    func testOwnedVerificationRejectsMalformedTrailingNonzeroAndOversizedOutput() async throws {
        let read = MalibuCatalogRead(mode: .verify, target: "local-candidate", modelKey: "local-candidate", context: String(repeating: "a", count: 64))
        let accepted = try readEvent(read, kind: "accepted", sequence: 1, bytes: 0)
        let completed = try readEvent(read, kind: "completed", sequence: 2, bytes: 10, projection: localProjection(prepared: true))
        let good = "puts(\(cString(accepted))); puts(\(cString(completed))); fflush(stdout);"
        let cases = [
            "fputs(\(cString(accepted)), stdout); return 0;", // incomplete JSONL frame
            "puts(\(cString(accepted))); puts(\(cString(accepted))); return 0;", // repeated sequence
            good + "return 7;",
            good + "puts(\(cString(accepted))); return 0;",
            "puts(\(cString(accepted))); for(int i=0;i<1048577;i++) putchar('a'); fflush(stdout); return 0;",
            "puts(\(cString(accepted))); for(int i=0;i<65537;i++) fputc('a',stderr); fflush(stderr); return 0;",
            "puts(\(cString(accepted))); puts(\(cString(Data(String(decoding: completed, as: UTF8.self).replacingOccurrences(of: read.id, with: UUID().uuidString.lowercased()).utf8)))); return 0;"
        ]
        for body in cases {
            let runner = MalibuCatalogReadRunner(), child = ReadFixtureChild(), executable = try compileReadFixture(body)
            do {
                _ = try await runner.run(read: read, paths: testProviderPaths(), timeout: 2,
                    resolve: { executable }, onSpawn: { _, pid in child.set(pid) }, progress: { _ in })
                XCTFail("unsafe output must not produce readiness")
            } catch {}
            for _ in 0..<100 where runner.isBusy { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(runner.isBusy)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(child.get(), &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }

    @MainActor
    func testActualCatalogCallerCapturesSpawnArgumentsForCLIParserBridge() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".omx/qualification/catalog-read")
        let input = directory.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("CLI signed fixture input has not been produced") }
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any])
        func string(_ key: String) throws -> String { try XCTUnwrap(values[key] as? String, key) }
        let quick = try string("quick_projection"), verified = try string("verified_projection"), recommendation = try string("recommendation_json")
        let target = try string("target_model_id"), key = try string("model_key"), context = try string("context_sha256")
        let read = MalibuCatalogRead(mode: .verify, id: "11111111-1111-4111-8111-111111111111", target: target, modelKey: key, context: context)
        func printEvent(_ data: Data) -> String {
            let parts = String(decoding: data, as: UTF8.self).components(separatedBy: read.id)
            precondition(parts.count == 2)
            return "fputs(\(cString(Data(parts[0].utf8))),stdout); fputs(request,stdout); puts(\(cString(Data(parts[1].utf8))));"
        }
        let body = """
        char *mode="", *request="";
        for(int i=1;i+1<argc;i++) { if(strcmp(argv[i],"--app-read-mode")==0)mode=argv[i+1]; if(strcmp(argv[i],"--app-read-request")==0)request=argv[i+1]; }
        if(strcmp(mode,"quick")==0) { puts(\(cString(Data(quick.utf8)))); }
        else if(strcmp(mode,"result")==0) { puts(\(cString(Data(recommendation.utf8)))); }
        else if(strcmp(mode,"verify")==0) {
            \(printEvent(try readEvent(read, kind: "accepted", sequence: 1, bytes: 0)))
            \(printEvent(try readEvent(read, kind: "completed", sequence: 2, bytes: 1, projection: verified)))
        } else return 9;
        return 0;
        """
        let executable = try compileReadFixture(body), cli = OwnedCatalogFixtureCLI(executable: executable)
        let home = URL(fileURLWithPath: try string("home"))
        let support = home.appendingPathComponent("Library/Application Support/Malibu")
        let paths = ProviderPaths(configFile: URL(fileURLWithPath: try string("config_path")), controlSocket: home.appendingPathComponent("fixture.sock"), cliLogFile: home.appendingPathComponent("cli.log"), launchdStdoutLog: home.appendingPathComponent("out.log"), launchdStderrLog: home.appendingPathComponent("err.log"), appSupport: support, appMarkerFile: support.appendingPathComponent("marker"), onboardingStateFile: support.appendingPathComponent("onboarding.json"), downloadsDirectory: support.appendingPathComponent("Downloads"))
        let store = ModelManagementStore(cli: cli, transactionControlCLI: cli, paths: paths, defaults: UserDefaults(suiteName: "read-bridge-\(UUID())")!)
        await store.refresh(currentModelID: "incumbent/model", peer: localPeer())
        let row = try XCTUnwrap(store.rows.first(where: { $0.id == target }))
        XCTAssertTrue(row.needsLocalVerification)
        await store.verifyLocalFiles(row)
        XCTAssertNotNil(store.recommendation, store.recommendationLine ?? store.statusLine)
        XCTAssertTrue(store.recommendationIsLocalActivation)
        let arrays = cli.spawned.get()
        XCTAssertEqual(arrays.count, 3)
        var artifact: [String: Any] = ["schema": "malibu_catalog_read_argv_fixture.v1"]
        for name in ["quick", "verify", "result"] {
            let arguments = try XCTUnwrap(arrays.first { args in args.firstIndex(of: "--app-read-mode").map { args[$0 + 1] == name } == true })
            XCTAssertFalse(arguments.contains("--ctl-socket-path"))
            artifact[name] = arguments
        }
        for name in ["config_path", "target_model_id", "model_key", "context_sha256", "transaction_id", "operation_generation"] { artifact[name] = try string(name) }
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("app-argv.json"), options: .atomic)
    }

    private func readEvent(_ read: MalibuCatalogRead, kind: String, sequence: UInt64, bytes: UInt64, projection: String? = nil) throws -> Data {
        let document: Any = try projection.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: ["schema":"model_catalog_read_event.v1", "request_id":read.id,
            "event_sequence":sequence, "target_model_id":read.target!, "model_key":read.modelKey!, "kind":kind,
            "bytes_completed":bytes, "error_code":NSNull(), "projection":document], options: [.sortedKeys])
    }
    private func cString(_ data: Data) -> String { String(decoding: try! JSONEncoder().encode(String(decoding: data, as: UTF8.self)), as: UTF8.self) }
    private func compileReadFixture(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("catalog-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("reader.c"), binary = root.appendingPathComponent("reader")
        try Data(("#include <stdio.h>\n#include <unistd.h>\n#include <signal.h>\n#include <string.h>\nint main(int argc, char **argv) {" + body + "}\n").utf8).write(to: source)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]; compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        return binary
    }

    private func ok(_ output: String) -> ModelCLIResult { ModelCLIResult(exitCode: 0, stdout: output, stderr: "") }
    private func localPeer() -> MalibuModelPeerEvidence {
        peer(for: [MalibuModelCapabilityManifest.catalogEconomics, MalibuModelCapabilityManifest.catalogTransactions, MalibuModelCapabilityManifest.localActivation, MalibuModelCapabilityManifest.recommendationAdoption, MalibuModelCapabilityManifest.catalogReadLifecycle])
    }
    private func localProjection(prepared: Bool = false, sequence: UInt64 = 1, kind: String = "prepare_model", adoption: Bool = false) -> String {
        var row = localOnlyBYOMRowJSON()
            .replacingOccurrences(of: "\"weights_present_locally\":true", with: "\"weights_present_locally\":\(prepared)")
            .replacingOccurrences(of: "\"runtime_state\":\"ready\"", with: "\"runtime_state\":\"\(prepared ? "ready" : "needs_preparation")\"")
        row = row.replacingOccurrences(of: "\"model_key\":", with: "\"local_verification\":{\"state\":\"\(prepared ? "verified" : "missing")\"},\"model_key\":")
        let field = kind == "evaluate_model" ? "evaluate" : "prepare"
        if !prepared || kind == "evaluate_model" {
            row = row.replacingOccurrences(of: "\"\(field)\":\(Self.unavailableActionJSON())", with: "\"\(field)\":\(availableActionJSON(kind: kind, timeout: 1800))")
        }
        if adoption {
            row = row.replacingOccurrences(of: "\"adopt_recommendation\":\(Self.unavailableActionJSON())", with: "\"adopt_recommendation\":\(availableActionJSON(kind: "adopt_recommendation", timeout: 1800))")
        }
        return catalogEconomicsJSON(rows: [row], generatedAt: ISO8601DateFormatter().string(from: Date()), projectionSequence: sequence)
            .replacingOccurrences(of: "\"projection_protocol_version\":\"1\"", with: "\"projection_protocol_version\":\"2\"")
            .replacingOccurrences(of: "\"rate_card_max_age_seconds\":604800", with: "\"rate_card_max_age_seconds\":604800,\"transaction_context_sha256\":\"" + String(repeating: "a", count: 64) + "\"")
            .replacingOccurrences(of: "\"transaction_id\":null", with: "\"operation_generation\":null,\"transaction_id\":null")
            .replacingOccurrences(of: "\"transaction_id\":\"\(transactionID)\"", with: "\"operation_generation\":\"\(transactionID)\",\"transaction_id\":\"\(transactionID)\"")
    }

    private func managedCatalogEconomicsJSON(rows: [String], generatedAt: String = "2026-08-09T00:00:00Z", rateCardSource: String = "live_signed", projectionSequence: UInt64 = 1) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(catalogEconomicsJSON(rows: rows.filter { !$0.contains("\"source\":\"local_default\"") }, generatedAt: generatedAt, rateCardSource: rateCardSource, projectionSequence: projectionSequence).utf8)) as! [String: Any]
        var source = object["source"] as! [String: Any]
        source["projection_protocol_version"] = "2"
        source["transaction_context_sha256"] = String(repeating: "a", count: 64)
        object["source"] = source
        object["rows"] = (object["rows"] as! [[String: Any]]).map { input in
            var row = input
            row["local_verification"] = ["state": "not_applicable"]
            for key in ["switch", "prepare", "evaluate", "adopt_recommendation", "cleanup_staging"] {
                var action = row[key] as! [String: Any]
                action["operation_generation"] = key == "switch" ? NSNull() : action["transaction_id"]
                row[key] = action
            }
            return row
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func quickProjection(_ verified: String) -> String {
        var document = try! JSONSerialization.jsonObject(with: Data(verified.utf8)) as! [String: Any]
        document["rows"] = (document["rows"] as! [[String: Any]]).map { input in
            var row = input
            if (row["local_verification"] as? [String: String])?["state"] == "verified" {
                row["local_verification"] = ["state": "unverified"]; row["weights_present_locally"] = false
                row["runtime_state"] = row["is_current"] as? Bool == true ? "current" : "verification_required"
                row["disabled_reason"] = "local_verification_required"
                var disabled = try! JSONSerialization.jsonObject(with: Data(Self.unavailableActionJSON().utf8)) as! [String: Any]
                disabled["operation_generation"] = NSNull(); disabled["unavailable_reason"] = "local_verification_required"
                for action in ["prepare", "evaluate", "adopt_recommendation", "switch"] { row[action] = disabled }
            }
            return row
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
    }

    private func catalogEconomicsJSON(
        rows: [String],
        generatedAt: String = "2026-08-09T00:00:00Z",
        rateCardSource: String = "live_signed",
        projectionSequence: UInt64 = 1
    ) -> String {
        """
        {"schema":"model_catalog_economics.v1","generated_at":"\(generatedAt)","projection_sequence":\(projectionSequence),"source":{"cli_version":"1.8.90","cli_build_commit":"test","process_launch_id":"c13c5d4c-3e4f-47ac-b72d-7f8f172747a0","process_started_at":"\(generatedAt)","projection_protocol_version":"1","rate_card_source":"\(rateCardSource)","rate_card_digest":"\(String(repeating: "a", count: 64))","rate_card_signature_digest":null,"demand_feed_digest":"\(String(repeating: "b", count: 64))","candidate_feed_digest":"\(String(repeating: "c", count: 64))","rate_card_max_age_seconds":604800},"rows":[\(rows.joined(separator: ","))],"warnings":[]}
        """
    }

    private func trustedEconomicsRowJSON(
        switchAction: String? = nil,
        economicsState: String = "trusted",
        admissionState: String = "catalog_priced",
        settlementCapable: Bool = false,
        rateCardGeneratedAt: String = "2026-08-09T00:00:00Z",
        stateObservedAt: String = "2026-08-09T00:00:00Z",
        warningCodesJSON: String = #"["admission_state_not_settlement_capable"]"#
    ) -> String {
        let switchAction = switchAction ?? Self.unavailableActionJSON()
        return """
        {"model_key":"qwen3-8b","served_model_id":"mlx-community/Qwen3-8B-4bit","display_model_id":"mlx-community/Qwen3-8B-4bit","action_model_id":"candidate-qwen","is_current":false,"weights_present_locally":true,"runtime_state":"catalog","estimated_gb":4.0,"fit":"fits","disabled_reason":null,"warning_codes":\(warningCodesJSON),"admission":{"state":"\(admissionState)","source":"coordinator","coordinator_event_id":"event-1","state_observed_at":"\(stateObservedAt)","catalog_economics_permitted":true,"settlement_capable":\(settlementCapable)},"rate_card_version":"rates-v1","rate_card_generated_at":"\(rateCardGeneratedAt)","rate_card_key":"qwen3-8b","rate_source":"live_signed","prompt_rate_usd_per_million_tokens":0.2,"completion_rate_usd_per_million_tokens":0.4,"provider_share_bps":9000,"provider_prompt_payout_usd_per_million_tokens":0.18,"provider_completion_payout_usd_per_million_tokens":0.36,"economics_state":"\(economicsState)","demand_rank":7,"demand_weight":0.65,"ready_provider_count":4,"supply_deficit_score":1.5,"switch":\(switchAction),"prepare":\(Self.unavailableActionJSON()),"evaluate":\(Self.unavailableActionJSON()),"adopt_recommendation":\(Self.unavailableActionJSON()),"cleanup_staging":\(Self.unavailableActionJSON())}
        """
    }

    private func localOnlyBYOMRowJSON() -> String {
        """
        {"model_key":"local-candidate","served_model_id":"local/byom","display_model_id":"local/byom","action_model_id":"local-candidate","is_current":false,"weights_present_locally":true,"runtime_state":"ready","estimated_gb":3.0,"fit":"fits","disabled_reason":"local_inventory_only","warning_codes":["admission_state_missing"],"admission":{"state":"local_only","source":"local_default","coordinator_event_id":null,"state_observed_at":null,"catalog_economics_permitted":false,"settlement_capable":false},"rate_card_version":null,"rate_card_generated_at":null,"rate_card_key":null,"rate_source":"none","prompt_rate_usd_per_million_tokens":null,"completion_rate_usd_per_million_tokens":null,"provider_share_bps":null,"provider_prompt_payout_usd_per_million_tokens":null,"provider_completion_payout_usd_per_million_tokens":null,"economics_state":"blocked","demand_rank":null,"demand_weight":null,"ready_provider_count":null,"supply_deficit_score":null,"switch":\(Self.unavailableActionJSON()),"prepare":\(Self.unavailableActionJSON()),"evaluate":\(Self.unavailableActionJSON()),"adopt_recommendation":\(Self.unavailableActionJSON()),"cleanup_staging":\(Self.unavailableActionJSON())}
        """
    }

    private static func unavailableActionJSON() -> String {
        """
        {"available":false,"requires_confirmation":false,"transaction_kind":null,"transaction_id":null,"action_timeout_seconds":null,"estimated_bytes":null,"unavailable_reason":"action_unavailable"}
        """
    }

    private func availableActionJSON(
        kind: String,
        timeout: Int,
        requiresConfirmation: Bool = true
    ) -> String {
        """
        {"available":true,"requires_confirmation":\(requiresConfirmation),"transaction_kind":"\(kind)","transaction_id":"c23c5d4c-3e4f-47ac-b72d-7f8f172747a0","action_timeout_seconds":\(timeout),"estimated_bytes":null,"unavailable_reason":null}
        """
    }

    private func peer(for capability: String) -> MalibuModelPeerEvidence {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        let tier = manifest.tiers[capability]!
        return peer(capabilities: tier.localStatusCapabilities
            .union(tier.commandSchemas)
            .union(tier.controlFrameSchemas), binaryVersion: tier.firstSupportingBinaryVersion)
    }

    private func peer(for capabilities: [String]) -> MalibuModelPeerEvidence {
        let manifest = MalibuModelCapabilityManifest.checkedIn
        var declaredCapabilities = Set<String>()
        var binaryVersion: String?
        let effective = capabilities.contains(MalibuModelCapabilityManifest.catalogEconomics)
            ? Array(Set(capabilities + [MalibuModelCapabilityManifest.catalogReadLifecycle, MalibuModelCapabilityManifest.catalogTransactions, MalibuModelCapabilityManifest.localActivation, MalibuModelCapabilityManifest.recommendationAdoption, MalibuModelCapabilityManifest.readySwitch])) : capabilities
        for capability in effective {
            let tier = manifest.tiers[capability]!
            declaredCapabilities.formUnion(tier.localStatusCapabilities)
            declaredCapabilities.formUnion(tier.commandSchemas)
            declaredCapabilities.formUnion(tier.controlFrameSchemas)
            if binaryVersion == nil
                || ProviderCLIVersion.compare(tier.firstSupportingBinaryVersion, binaryVersion!) == .descending {
                binaryVersion = tier.firstSupportingBinaryVersion
            }
        }
        return peer(capabilities: declaredCapabilities, binaryVersion: binaryVersion!)
    }

    private func peer(capabilities: Set<String>, binaryVersion: String) -> MalibuModelPeerEvidence {
        return MalibuModelPeerEvidence(
            binaryVersion: binaryVersion,
            capabilities: capabilities,
            contractCompatible: true,
            lifecycleOwner: "macprovider_cli",
            serviceInstanceID: "instance",
            servicePID: Int(getpid()),
            observedAt: Date(),
            observationValidForMS: 5_000,
            observationFresh: true
        )
    }

    private func testProviderPaths() -> ProviderPaths {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("malibu-model-management-tests-\(UUID().uuidString)", isDirectory: true)
        return ProviderPaths(
            configFile: root.appendingPathComponent("config.yaml"),
            controlSocket: root.appendingPathComponent("ctl.sock"),
            cliLogFile: root.appendingPathComponent("cli.log"),
            launchdStdoutLog: root.appendingPathComponent("out.log"),
            launchdStderrLog: root.appendingPathComponent("err.log"),
            appSupport: root,
            appMarkerFile: root.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: root.appendingPathComponent("onboarding.json"),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    private static func recentTimestamp() -> String {
        timestamp(offset: 0)
    }

    private static func timestamp(offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(offset))
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

@MainActor
private final class FakeModelCLI: MalibuModelCLIRunning {
    var invocations: [[String]] = []
    var stdinPayloads: [Data?] = []
    private var results: [ModelCLIResult]
    private let returnDelaysNanoseconds: [UInt64?]

    init(results: [ModelCLIResult], returnDelaysNanoseconds: [UInt64?] = []) {
        self.results = results
        self.returnDelaysNanoseconds = returnDelaysNanoseconds
    }

    func readCatalog(_ read: MalibuCatalogRead, paths: ProviderPaths, peer: MalibuModelPeerEvidence, timeout: TimeInterval,
                     progress: @escaping @MainActor @Sendable (MalibuCatalogReadProgress) -> Void) async throws -> ModelCLIResult {
        let result = try await run(arguments: read.arguments(paths: paths), peer: peer, stdinData: nil, priority: .interactive, onLine: { _ in })
        if invocations.count <= returnDelaysNanoseconds.count,
           let delay = returnDelaysNanoseconds[invocations.count - 1], Double(delay) / 1_000_000_000 >= timeout { throw ModelManagementError.invalidCatalog }
        return result
    }
    // State-machine tests fake native resource custody. Resource tests exercise
    // the production clear path with explicit fixture identity verification.
    func finishCatalog(_ pending: MalibuPendingCatalogTransaction, paths: ProviderPaths) async throws {
        try MalibuTransactionFiles.save(nil, paths: paths)
    }
    func authorizeCatalog(_ pending: MalibuPendingCatalogTransaction, contextDigest: String, peer: MalibuModelPeerEvidence, paths: ProviderPaths) async throws -> MalibuTransactionPin {
        let pin = MalibuTransactionPin(code: .init(cdHash: Data([1]), identifier: "fixture", team: "fixture"), configuredPath: "/fixture", binaryVersion: "1.8.90", capabilities: peer.capabilities,
            manifestDigest: MalibuModelCapabilityManifest.checkedIn.controlDigest,
            context: .init(transactionContextSHA256: contextDigest, configPath: paths.configFile.path, configDevice: 1, configInode: 1, configSize: 1, configSHA256: String(repeating: "a", count: 64), uid: UInt64(getuid()), homeDirectory: NSHomeDirectory()), inventory: fixturePayloadInventory())
        var saved = pending; saved.pin = pin
        try MalibuTransactionFiles.save(saved, paths: paths)
        return pin
    }
    func runCatalog(_ pending: MalibuPendingCatalogTransaction, control: MalibuCatalogControl?, peer: MalibuModelPeerEvidence?, paths: ProviderPaths,
                    onLine: @escaping @MainActor @Sendable (String) -> Void) async throws -> ModelCLIResult {
        if control == .cancel { try MalibuTransactionFiles.save(pending, paths: paths) }
        return try await run(arguments: pending.arguments(control: control, paths: paths), peer: peer, stdinData: nil, priority: .interactive, onLine: onLine)
    }

    func run(
        arguments: [String],
        peer: MalibuModelPeerEvidence?,
        stdinData: Data?,
        priority: ModelCLIWorkPriority,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ModelCLIResult {
        let invocationIndex = invocations.count
        invocations.append(arguments)
        stdinPayloads.append(stdinData)
        guard !results.isEmpty else {
            return ModelCLIResult(exitCode: 1, stdout: "", stderr: "missing fake result")
        }
        let result = results.removeFirst()
        if invocationIndex < returnDelaysNanoseconds.count,
           let delay = returnDelaysNanoseconds[invocationIndex] {
            try await Task.sleep(nanoseconds: delay)
        }
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            onLine(String(line))
        }
        return result
    }
}

private func fixturePayloadInventory() -> MalibuPayloadInventory {
    let names = MalibuTransactionPayload.requiredFiles.union(MalibuTransactionPayload.localFiles.map { "compatibility-set-local/" + $0 }).union(MalibuTransactionPayload.catalogFiles.map { "catalog-release/" + $0 }).union(["swift-nio_NIOPosix.bundle/PrivacyInfo.xcprivacy", "swift-nio_NIOPosix.bundle/Info.plist"])
    return .init(files: names.sorted().map { .init(relativePath: $0, size: 1, sha256: String(repeating: "a", count: 64)) }, directories: ["catalog-release", "compatibility-set-local", "swift-nio_NIOPosix.bundle"])
}

final class ModelTransactionResourceTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("malibu-resource-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ parent: URL, name: String = "source") throws -> URL {
        let source = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in fixturePayloadInventory().directories {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for file in fixturePayloadInventory().files {
            let url = source.appendingPathComponent(file.relativePath)
            let data = file.relativePath.hasSuffix("Info.plist")
                ? try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.resources"], format: .xml, options: 0)
                : Data("fixture".utf8)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: file.relativePath == "macprovider-cli" ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
        return source
    }
    func testResourceCaptureCopiesOnlyCompleteNamedClosure() throws {
        let parent = try root(), source = try fixture(parent), destination = parent.appendingPathComponent("payload")
        try Data("untouched".utf8).write(to: source.appendingPathComponent("unrelated-operator-data"))
        let before = try MalibuTransactionPayload.scan(source, source: true)
        try MalibuTransactionPayload.copy(source: source, destination: destination, scan: before, request: MalibuTransactionRequest(timeout: 10))
        XCTAssertEqual(try MalibuTransactionPayload.scan(destination, source: false).inventory, before.inventory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("unrelated-operator-data").path))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(destination, source: false))
        XCTAssertNoThrow(try MalibuTransactionPayload.scan(destination, source: false, complete: false))
    }
    func testSourceMutationCannotCompleteFrozenCopy() throws {
        let parent = try root(), source = try fixture(parent)
        let before = try MalibuTransactionPayload.scan(source, source: true)
        try Data("changed".utf8).write(to: source.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try MalibuTransactionPayload.copy(source: source, destination: parent.appendingPathComponent("partial"), scan: before, request: MalibuTransactionRequest(timeout: 10)))
        if FileManager.default.fileExists(atPath: parent.appendingPathComponent("partial").path) {
            XCTAssertNoThrow(try MalibuTransactionPayload.removePartial(parent.appendingPathComponent("partial"), checkAbsent: {}))
        }
    }
    func testInterruptedCopyAtEveryMemberRemainsDeletionOnly() throws {
        let parent = try root(), source = try fixture(parent), observed = try MalibuTransactionPayload.scan(source, source: true)
        for index in 1...observed.inventory.files.count {
            let counter = ResourceWriteCounter(stop: index)
            let request = MalibuTransactionRequest(timeout: 10, afterPayloadWrite: { counter.didWrite($0) })
            let destination = parent.appendingPathComponent("partial-\(index)")
            XCTAssertThrowsError(try MalibuTransactionPayload.copy(source: source, destination: destination, scan: observed, request: request))
            XCTAssertNoThrow(try MalibuTransactionPayload.removePartial(destination, checkAbsent: {}))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testRetirementCrashRestoresOnlyCompletePinnedPayload() throws {
        let parent = try root(), source = try fixture(parent), observed = try MalibuTransactionPayload.scan(source, source: true)
        let config = parent.appendingPathComponent("config.yaml"), support = parent.appendingPathComponent("Malibu")
        let paths = ProviderPaths(configFile: config, controlSocket: parent.appendingPathComponent("ctl"), cliLogFile: parent.appendingPathComponent("log"), launchdStdoutLog: parent.appendingPathComponent("out"), launchdStderrLog: parent.appendingPathComponent("err"), appSupport: support, appMarkerFile: parent.appendingPathComponent("marker"), onboardingStateFile: parent.appendingPathComponent("onboard"), downloadsDirectory: parent.appendingPathComponent("downloads"))
        let code = MalibuTransactionCodeIdentity(cdHash: Data([1, 2]), identifier: "fixture-only", team: "fixture-only")
        let pin = MalibuTransactionPin(code: code, configuredPath: source.appendingPathComponent("macprovider-cli").path, binaryVersion: "1.8.90", capabilities: [], manifestDigest: String(repeating: "a", count: 64), context: .init(transactionContextSHA256: String(repeating: "a", count: 64), configPath: config.path, configDevice: 1, configInode: 1, configSize: 1, configSHA256: String(repeating: "b", count: 64), uid: UInt64(getuid()), homeDirectory: NSHomeDirectory()), inventory: observed.inventory)
        let pending = MalibuPendingCatalogTransaction(id: UUID().uuidString.lowercased(), target: "model", modelKey: "model", kind: "prepare_model", timeoutSeconds: 30, startedAt: Date(), operationGeneration: UUID().uuidString.lowercased(), pin: pin)
        let active = try MalibuTransactionFiles.payload(paths, id: pending.id, pin: pin), retired = try MalibuTransactionFiles.retired(paths, id: pending.id, pin: pin)
        try MalibuTransactionFiles.ensureDirectory(active.deletingLastPathComponent())
        try MalibuTransactionPayload.copy(source: source, destination: active, scan: observed, request: MalibuTransactionRequest(timeout: 10))
        try MalibuTransactionFiles.save(pending, paths: paths)
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, nativeIdentity: { _ in code }, afterRetirement: { throw ModelManagementError.invalidCatalog }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        XCTAssertEqual(try MalibuTransactionFiles.load(paths: paths), pending)
        XCTAssertNoThrow(try MalibuTransactionFiles.restoreRetired(pending, paths: paths, request: MalibuTransactionRequest(timeout: 10), nativeIdentity: { _ in code }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, nativeIdentity: { _ in code }, afterRetirement: { throw ModelManagementError.invalidCatalog }))
        try FileManager.default.removeItem(at: retired.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try MalibuTransactionFiles.restoreRetired(pending, paths: paths, request: MalibuTransactionRequest(timeout: 10), nativeIdentity: { _ in code }))
        XCTAssertThrowsError(try MalibuTransactionFiles.collectOrphans(paths: paths, request: MalibuTransactionRequest(timeout: 10)))
        // Only confirmed removal of private pending metadata changes the custody
        // predicate. This fixture models post-clear interrupted orphan deletion.
        try FileManager.default.removeItem(at: MalibuTransactionFiles.pendingURL(paths))
        XCTAssertNoThrow(try MalibuTransactionFiles.collectOrphans(paths: paths, request: MalibuTransactionRequest(timeout: 10)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }
    func testPendingUnlinkSyncFailureRetainsCustodyAndRetryRequiresBarrier() throws {
        let parent = try root(), source = try fixture(parent), observed = try MalibuTransactionPayload.scan(source, source: true)
        let config = parent.appendingPathComponent("config.yaml"), support = parent.appendingPathComponent("Malibu")
        let paths = ProviderPaths(configFile: config, controlSocket: parent.appendingPathComponent("ctl"), cliLogFile: parent.appendingPathComponent("log"), launchdStdoutLog: parent.appendingPathComponent("out"), launchdStderrLog: parent.appendingPathComponent("err"), appSupport: support, appMarkerFile: parent.appendingPathComponent("marker"), onboardingStateFile: parent.appendingPathComponent("onboard"), downloadsDirectory: parent.appendingPathComponent("downloads"))
        let code = MalibuTransactionCodeIdentity(cdHash: Data([1, 2]), identifier: "fixture-only", team: "fixture-only")
        let pin = MalibuTransactionPin(code: code, configuredPath: source.appendingPathComponent("macprovider-cli").path, binaryVersion: "1.8.90", capabilities: [], manifestDigest: String(repeating: "a", count: 64), context: .init(transactionContextSHA256: String(repeating: "a", count: 64), configPath: config.path, configDevice: 1, configInode: 1, configSize: 1, configSHA256: String(repeating: "b", count: 64), uid: UInt64(getuid()), homeDirectory: NSHomeDirectory()), inventory: observed.inventory)
        let pending = MalibuPendingCatalogTransaction(id: UUID().uuidString.lowercased(), target: "model", modelKey: "model", kind: "prepare_model", timeoutSeconds: 30, startedAt: Date(), operationGeneration: UUID().uuidString.lowercased(), pin: pin)
        let active = try MalibuTransactionFiles.payload(paths, id: pending.id, pin: pin), retired = try MalibuTransactionFiles.retired(paths, id: pending.id, pin: pin)
        try MalibuTransactionFiles.ensureDirectory(active.deletingLastPathComponent())
        try MalibuTransactionPayload.copy(source: source, destination: active, scan: observed, request: MalibuTransactionRequest(timeout: 10))
        try MalibuTransactionFiles.save(pending, paths: paths)
        var unlinkedBeforeFailure = false
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, nativeIdentity: { _ in code }, pendingDirectorySync: { _ in
            unlinkedBeforeFailure = try !MalibuTransactionFiles.exists(MalibuTransactionFiles.pendingURL(paths))
            throw ModelManagementError.invalidCatalog
        }))
        XCTAssertTrue(unlinkedBeforeFailure)
        XCTAssertEqual(try MalibuTransactionFiles.load(paths: paths), pending)
        XCTAssertEqual(try MalibuTransactionPayload.scan(retired, source: false).inventory, observed.inventory)
        XCTAssertThrowsError(try MalibuTransactionFiles.collectOrphans(paths: paths, request: MalibuTransactionRequest(timeout: 10)))
        // A fresh instance can recover the crash-equivalent old-record/intact-
        // retired state. No state from the failed caller is required.
        XCTAssertNoThrow(try MalibuTransactionFiles.restoreRetired(try XCTUnwrap(MalibuTransactionFiles.load(paths: paths)), paths: paths, request: MalibuTransactionRequest(timeout: 10), nativeIdentity: { _ in code }))
        XCTAssertTrue(try MalibuTransactionFiles.exists(active))
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, nativeIdentity: { _ in code }, afterRetirement: { throw ModelManagementError.invalidCatalog }))
        // Model app death immediately after unlink, before restoration or sync.
        XCTAssertEqual(unlink(MalibuTransactionFiles.pendingURL(paths).path), 0)
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, pendingDirectorySync: { _ in throw ModelManagementError.invalidCatalog }))
        XCTAssertThrowsError(try MalibuTransactionFiles.collectOrphans(paths: paths, request: MalibuTransactionRequest(timeout: 10), pendingDirectorySync: { _ in throw ModelManagementError.invalidCatalog }))
        XCTAssertEqual(try MalibuTransactionPayload.scan(retired, source: false).inventory, observed.inventory)
        var completionSynced = false
        XCTAssertNoThrow(try MalibuTransactionFiles.clear(pending, paths: paths, pendingDirectorySync: { url in
            try MalibuTransactionFiles.syncDirectory(url); completionSynced = true
        }))
        XCTAssertTrue(completionSynced)
        var disposalSynced = false
        XCTAssertNoThrow(try MalibuTransactionFiles.collectOrphans(paths: paths, request: MalibuTransactionRequest(timeout: 10), pendingDirectorySync: { url in
            XCTAssertTrue(try MalibuTransactionFiles.exists(retired.appendingPathComponent("mlx.metallib")))
            try MalibuTransactionFiles.syncDirectory(url); disposalSynced = true
        }))
        XCTAssertTrue(disposalSynced)
        XCTAssertFalse(try MalibuTransactionFiles.exists(retired))
    }
    func testPendingClearRejectsMissingBothPayloads() throws {
        let parent = try root(), source = try fixture(parent), observed = try MalibuTransactionPayload.scan(source, source: true)
        let config = parent.appendingPathComponent("config.yaml"), support = parent.appendingPathComponent("Malibu")
        let paths = ProviderPaths(configFile: config, controlSocket: parent.appendingPathComponent("ctl"), cliLogFile: parent.appendingPathComponent("log"), launchdStdoutLog: parent.appendingPathComponent("out"), launchdStderrLog: parent.appendingPathComponent("err"), appSupport: support, appMarkerFile: parent.appendingPathComponent("marker"), onboardingStateFile: parent.appendingPathComponent("onboard"), downloadsDirectory: parent.appendingPathComponent("downloads"))
        let code = MalibuTransactionCodeIdentity(cdHash: Data([1, 2]), identifier: "fixture-only", team: "fixture-only")
        let pin = MalibuTransactionPin(code: code, configuredPath: source.appendingPathComponent("macprovider-cli").path, binaryVersion: "1.8.90", capabilities: [], manifestDigest: String(repeating: "a", count: 64), context: .init(transactionContextSHA256: String(repeating: "a", count: 64), configPath: config.path, configDevice: 1, configInode: 1, configSize: 1, configSHA256: String(repeating: "b", count: 64), uid: UInt64(getuid()), homeDirectory: NSHomeDirectory()), inventory: observed.inventory)
        let pending = MalibuPendingCatalogTransaction(id: UUID().uuidString.lowercased(), target: "model", modelKey: "model", kind: "prepare_model", timeoutSeconds: 30, startedAt: Date(), operationGeneration: UUID().uuidString.lowercased(), pin: pin)
        let active = try MalibuTransactionFiles.payload(paths, id: pending.id, pin: pin), retired = try MalibuTransactionFiles.retired(paths, id: pending.id, pin: pin)
        try MalibuTransactionFiles.ensureDirectory(active.deletingLastPathComponent())
        try MalibuTransactionPayload.copy(source: source, destination: active, scan: observed, request: MalibuTransactionRequest(timeout: 10))
        try MalibuTransactionFiles.save(pending, paths: paths)
        try FileManager.default.removeItem(at: active)
        XCTAssertFalse(try MalibuTransactionFiles.exists(retired))
        XCTAssertThrowsError(try MalibuTransactionFiles.clear(pending, paths: paths, nativeIdentity: { _ in code }))
        XCTAssertEqual(try MalibuTransactionFiles.load(paths: paths), pending)
    }
    func testEverySelectedBundleRequiresFlatOrContentsMetadata() throws {
        let parent = try root()
        for bundleName in MalibuTransactionPayload.bundles.sorted() {
            for useContents in [false, true] {
                let source = try fixture(parent, name: UUID().uuidString)
                let bundle = source.appendingPathComponent(bundleName)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let flat = bundle.appendingPathComponent("Info.plist")
                if try MalibuTransactionFiles.exists(flat) { try FileManager.default.removeItem(at: flat) }
                XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
                XCTAssertNoThrow(try MalibuTransactionPayload.scan(source, source: false, complete: false))
                let metadata = useContents ? bundle.appendingPathComponent("Contents/Info.plist") : flat
                try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.resources"], format: .xml, options: 0).write(to: metadata)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
                XCTAssertNoThrow(try MalibuTransactionPayload.scan(source, source: true))
                try FileManager.default.removeItem(at: metadata)
                XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
                XCTAssertNoThrow(try MalibuTransactionPayload.removePartial(source, checkAbsent: {}))
            }
        }
    }
    func testResourceBundleRejectsExtraNativeAndExecutableMetadata() throws {
        let parent = try root(), source = try fixture(parent)
        let bundle = source.appendingPathComponent("swift-nio_NIOPosix.bundle")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "helper"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.resources"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe,0,0,0,0]).write(to: source.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
        try Data("fixture".utf8).write(to: source.appendingPathComponent("mlx.metallib"))
        try Data().write(to: bundle.appendingPathComponent("unknown"))
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
        XCTAssertThrowsError(try MalibuTransactionPayload.removePartial(source, checkAbsent: {}))
    }
    func testResourceUnsafeLinksAndSparseOversizeRejectBeforeCopy() throws {
        let parent = try root(), source = try fixture(parent)
        let library = source.appendingPathComponent("mlx.metallib"), outside = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: outside)
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
        XCTAssertThrowsError(try MalibuTransactionPayload.removePartial(source, checkAbsent: {}))
        try FileManager.default.removeItem(at: library)
        XCTAssertEqual(link(outside.path, library.path), 0)
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
        try FileManager.default.removeItem(at: library)
        let fd = open(library.path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(MalibuTransactionPayload.maximumBytes / 2 + 1)), 0); close(fd)
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(source, source: true))
    }
    func testPartialDisposalSurvivesEachMissingRequiredMemberAndEmptyDirectories() throws {
        let parent = try root()
        for (index, file) in fixturePayloadInventory().files.enumerated() {
            let source = try fixture(parent, name: "partial-\(index)")
            let original = try MalibuTransactionPayload.scan(source, source: false).inventory
            try FileManager.default.removeItem(at: source.appendingPathComponent(file.relativePath))
            if let surviving = try? MalibuTransactionPayload.scan(source, source: false).inventory { XCTAssertNotEqual(surviving, original) }
            XCTAssertNoThrow(try MalibuTransactionPayload.removePartial(source, checkAbsent: {}))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
        let empty = parent.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("catalog-release"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertNoThrow(try MalibuTransactionPayload.removePartial(empty, checkAbsent: {}))
    }
    func testPartialDisposalRejectsConflictingPendingAndSubstitution() throws {
        let parent = try root(), source = try fixture(parent)
        XCTAssertThrowsError(try MalibuTransactionPayload.removePartial(source) { throw ModelManagementError.invalidCatalog })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("macprovider-cli").path))
        var checks = 0
        XCTAssertThrowsError(try MalibuTransactionPayload.removePartial(source) {
            checks += 1
            if checks == 2 {
                try FileManager.default.moveItem(at: source, to: parent.appendingPathComponent("moved"))
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("moved/macprovider-cli").path))
    }
    private func compileTool(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        XCTAssertEqual(process.terminationStatus, 0, "Metal fixture compilation must succeed")
    }
    func testCompiledMetalLibraryLoadsFromCapturedPayload() throws {
        let parent = try root(), source = try fixture(parent), destination = parent.appendingPathComponent("captured-metal")
        let metal = parent.appendingPathComponent("probe.metal"), air = parent.appendingPathComponent("probe.air")
        try Data("#include <metal_stdlib>\nusing namespace metal;\nkernel void snapshot_resource_probe(device uint* out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = id + 1; }\n".utf8).write(to: metal)
        try compileTool(["-sdk", "macosx", "metal", "-c", metal.path, "-o", air.path])
        try compileTool(["-sdk", "macosx", "metallib", air.path, "-o", source.appendingPathComponent("mlx.metallib").path])
        let observed = try MalibuTransactionPayload.scan(source, source: true)
        try MalibuTransactionPayload.copy(source: source, destination: destination, scan: observed, request: MalibuTransactionRequest(timeout: 30))
        XCTAssertEqual(try MalibuTransactionPayload.scan(destination, source: false).inventory, observed.inventory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(URL: destination.appendingPathComponent("mlx.metallib"))
        XCTAssertNotNil(library.makeFunction(name: "snapshot_resource_probe"))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try device.makeLibrary(URL: destination.appendingPathComponent("mlx.metallib")))
    }
    @MainActor
    func testPinnedMLXExpressionUsesProductionResourceCopy() async throws {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while repository.lastPathComponent != "phase3-binary", repository.path != "/" { repository.deleteLastPathComponent() }
        let probes = repository.deletingLastPathComponent().appendingPathComponent(".omx/qualification/mlx")
        guard FileManager.default.fileExists(atPath: probes.appendingPathComponent("macprovider-cli").path),
              FileManager.default.fileExists(atPath: probes.appendingPathComponent("mlx.metallib").path) else {
            throw XCTSkip("Non-shipping pinned MLX helper and compiled library qualification artifacts are required")
        }
        let parent = try root(), source = try fixture(parent), destination = parent.appendingPathComponent("captured-mlx")
        for name in ["macprovider-cli", "mlx.metallib"] {
            try FileManager.default.removeItem(at: source.appendingPathComponent(name))
            try FileManager.default.copyItem(at: probes.appendingPathComponent(name), to: source.appendingPathComponent(name))
        }
        let inventory = try await MalibuTransactionWorker().run(timeout: 30) { request in
            let observed = try MalibuTransactionPayload.scan(source, source: true, request: request)
            try MalibuTransactionPayload.copy(source: source, destination: destination, scan: observed, request: request)
            let copied = try MalibuTransactionPayload.scan(destination, source: false, request: request)
            guard copied.inventory == observed.inventory else { throw ModelManagementError.invalidCatalog }
            return copied.inventory
        }
        XCTAssertTrue(inventory.files.contains { $0.relativePath == "mlx.metallib" && $0.size > 1_000_000 })
        let result = try await MalibuBoundedCatalogProcess.run(executable: destination.appendingPathComponent("macprovider-cli"), arguments: [], expectation: Data("{}".utf8), environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], lockDirectory: parent.appendingPathComponent("lease"), control: true, timeout: 10, resultDocument: true, onLine: { _ in })
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("MLX_GPU_PROBE_OK values=[3.0, 5.0, 7.0]"), result.stdout)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("mlx.metallib"))
        XCTAssertThrowsError(try MalibuTransactionPayload.scan(destination, source: false))
    }
    func testInventoryClosedShapeBoundsAndTraversal() throws {
        let valid = fixturePayloadInventory(), data = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(MalibuPayloadInventory.self, from: data), valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["untrusted_path"] = "/outside"
        XCTAssertThrowsError(try JSONDecoder().decode(MalibuPayloadInventory.self, from: JSONSerialization.data(withJSONObject: object)))
        let bad = MalibuPayloadInventory(files: [.init(relativePath: "../mlx.metallib", size: 1, sha256: String(repeating: "a", count: 64))], directories: [])
        XCTAssertThrowsError(try MalibuTransactionPayload.validate(bad, complete: false))
        let oversized = MalibuPayloadInventory(files: [.init(relativePath: "mlx.metallib", size: MalibuTransactionPayload.maximumBytes, sha256: String(repeating: "a", count: 64))], directories: [])
        XCTAssertThrowsError(try MalibuTransactionPayload.validate(oversized, complete: false))
    }
    @MainActor
    func testStalledResourceReadTimesOutWithoutLateAuthorizationOrWorkerGrowth() async throws {
        let parent = try root(), source = try fixture(parent)
        let gate = ResourceReadGate(), worker = MalibuTransactionWorker()
        let request = MalibuTransactionRequest(timeout: 10, beforeResourceRead: { gate.pauseOnce() })
        let task = Task {
            try await worker.run(request: request) { request in
                _ = try MalibuTransactionPayload.scan(source, source: true, request: request)
                gate.markAuthorized()
                return true
            }
        }
        while !gate.entered { try await Task.sleep(nanoseconds: 10_000_000) }
        let started = Date()
        do { _ = try await task.value; XCTFail("stalled resource validation must time out") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.8)
        XCTAssertTrue(worker.isBusy)
        for _ in 0..<3 {
            do { _ = try await worker.run { _ in true }; XCTFail("retained worker must reject another request") } catch { }
        }
        XCTAssertFalse(gate.authorized)
        gate.release()
        while worker.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(gate.authorized)
        let subsequent = try await worker.run { _ in true }
        XCTAssertTrue(subsequent)
    }
    @MainActor
    func testAbandonedPreflightKeepsLeaseUntilReadReturns() async throws {
        let parent = try root(), source = try fixture(parent), gate = ResourceReadGate(), worker = MalibuTransactionWorker()
        let request = MalibuTransactionRequest(timeout: 10, beforeResourceRead: { gate.pauseOnce() })
        let lockPath = parent.appendingPathComponent("control.lock")
        let task = Task {
            try await worker.run(request: request) { request in
                let fd = open(lockPath.path, O_CREAT | O_RDWR, 0o600); defer { close(fd) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ModelManagementError.invalidCatalog }
                _ = try MalibuTransactionPayload.scan(source, source: true, request: request)
                gate.markAuthorized()
                return true
            }
        }
        while !gate.entered { try await Task.sleep(nanoseconds: 10_000_000) }
        request.revoke()
        do { _ = try await task.value; XCTFail("abandonment must finish the UI request") } catch { }
        let other = open(lockPath.path, O_RDWR); defer { close(other) }
        XCTAssertNotEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(worker.isBusy)
        gate.release()
        while worker.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        XCTAssertFalse(gate.authorized)
    }
}

private final class ResourceReadGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false, didAuthorize = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    var authorized: Bool { lock.lock(); defer { lock.unlock() }; return didAuthorize }
    func pauseOnce() {
        lock.lock(); let first = !didEnter; didEnter = true; lock.unlock()
        if first { semaphore.wait() }
    }
    func markAuthorized() { lock.lock(); didAuthorize = true; lock.unlock() }
    func release() { semaphore.signal() }
}

private final class ResourceWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let stop: Int
    init(stop: Int) { self.stop = stop }
    func didWrite(_ request: MalibuTransactionRequest) {
        lock.lock(); count += 1; let revoke = count == stop; lock.unlock()
        if revoke { request.revoke() }
    }
}

private final class ReadFixtureChild: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t = 0
    func set(_ value: pid_t) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> pid_t { lock.lock(); defer { lock.unlock() }; return value }
}


private final class CatalogFixtureSpawns: @unchecked Sendable {
    private let lock = NSLock()
    private var arrays: [[String]] = []
    func append(_ value: [String]) { lock.lock(); arrays.append(value); lock.unlock() }
    func get() -> [[String]] { lock.lock(); defer { lock.unlock() }; return arrays }
}

@MainActor
private final class OwnedCatalogFixtureCLI: MalibuModelCLIRunning {
    let runner = MalibuCatalogReadRunner()
    let executable: URL
    let spawned = CatalogFixtureSpawns()
    init(executable: URL) { self.executable = executable }
    var catalogReadIsBusy: Bool { runner.isBusy }
    func cancelCatalogRead() { runner.cancel() }
    func readCatalog(_ read: MalibuCatalogRead, paths: ProviderPaths, peer: MalibuModelPeerEvidence, timeout: TimeInterval,
                     progress: @escaping @MainActor @Sendable (MalibuCatalogReadProgress) -> Void) async throws -> ModelCLIResult {
        let executable = self.executable, spawned = self.spawned
        return try await runner.run(read: read, paths: paths, timeout: timeout, resolve: { executable },
            onSpawn: { args, _ in spawned.append(args) }, progress: progress)
    }
    func run(arguments: [String], peer: MalibuModelPeerEvidence?, stdinData: Data?, priority: ModelCLIWorkPriority,
             onLine: @escaping @MainActor @Sendable (String) -> Void) async throws -> ModelCLIResult {
        XCTFail("Catalog caller escaped the owned runner")
        throw ModelManagementError.invalidCatalog
    }
}
