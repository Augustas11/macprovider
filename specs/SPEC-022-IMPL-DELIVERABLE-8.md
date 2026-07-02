# SPEC-022 implementation deliverable 8

Status: acceptance gate mapped and locally validated; enforce/full-product ship
gate remains blocked until the listed non-covered acceptance rows are closed.

## Result

D8 converts the build prompt's final acceptance gate into a concrete coverage
map for every SPEC-022 acceptance criterion. The map separates deterministic
automated coverage, partial component evidence, conditional manual gates, and
launch blockers.

The current implementation has deterministic coverage for the non-streaming
signed-receipt money path, route snapshots, SPEC-015 v0.4 receipt verification,
streaming terminal-output capture, late-receipt quarantine, gateway quota
reservation primitives, Tier 2 model-hash disclosure, SPEC-022 buyer disclosure
surfaces, and provider-facing late-receipt deadline docs. It is not yet ready
for enforce-mode launch because the streaming money path, enforce-mode
configuration gate, race harnesses, and full e2e/live-network gates are not
fully proven in this branch. D9-D14 moved several money-path rows from blocked
to partial coverage; the remaining launch gap is cross-service proof,
activation/policy gating, race/failover coverage, and final e2e evidence, not
lack of component primitives.

## Blocking gaps before enforce launch

- **AC-022-13 / AC-022-15 / AC-022-33 / AC-022-63:** finish the full-path
  gateway plus coordinator harness proving only signed, catalog-matching
  settlement receipts can create final buyer debit and positive provider credit
  for streaming requests and cross-module e2e release gates.
- **AC-022-4:** add coordinator-side covered-routing tests proving warm-swap
  loading or draining providers fail the SPEC-022 target-model predicate and
  cannot receive paid covered work.
- **AC-022-9 / AC-022-30:** add full money-path replay/legacy receipt tests
  proving rejected receipts cannot create buyer debit or provider settlement.
- **AC-022-19 / AC-022-20 / AC-022-21 / AC-022-29 / AC-022-43 / AC-022-51:**
  add the explicit `verified_model_settlement` policy/profile activation gate
  and tests for every paid entrypoint and streaming terminal-state prerequisite.
- **AC-022-23 / AC-022-39 / AC-022-52:** finish compensation-path inventory
  and true multi-worker e2e coverage. D9-D14 now reject manual payout-ready,
  forged-source, mutated-source, pending, and quarantined rows at payout claim
  time, but the full admin/operator compensation and cross-process concurrency
  gates are still open.
- **AC-022-14 / AC-022-31 / AC-022-34 / AC-022-48:** finish full money-path
  and route-time catalog-expiry assertions for currently component-covered
  receipt deadline, idempotency, and late-arrival behavior.
- **AC-022-22:** add rollback tests proving existing enforce rows retain payout
  exclusion and pending deadline behavior after rollback to observe.
- **AC-022-36:** add a pinned stock OpenAI-compatible streaming-client smoke
  proving SPEC-022 receipt transport does not break `[DONE]` consumption.
- **AC-022-57:** finish full settlement and rollback tests proving every
  covered ledger row reads immutable request-start policy data. D9/D14 now
  preserve policy snapshot data and immutable settled source linkage for the
  component paths.
- **AC-022-27 / AC-022-47 / AC-022-49 / AC-022-62:** finish acceptance
  harnesses for receipt/sweep race orderings, concurrent agentic quota
  reservations, and receipt-aware streaming failover. D13/D14 cover the
  component idempotency pieces but not the full race/failover matrix.

## AC coverage table

Refresh note: this table has been updated through D14 implementation evidence.
Rows remain **Partial** where component coverage is now strong but the full
cross-service buyer-debit, provider-credit, payout, race, or live-network e2e
gate is still missing.

Status legend:

- **Covered**: deterministic automated coverage exists for the criterion as
  written, using current files and test functions.
- **Partial**: current component coverage exists, but the full AC needs an
  additional cross-module, disclosure, race, or end-to-end assertion.
- **Manual gate**: conditional surface is absent or operator-controlled; the
  gate must be checked before release.
- **Blocked**: required deterministic coverage or product surface is missing.

| AC | Status | Coverage / required gate |
| --- | --- | --- |
| AC-022-1 | Covered | `phase4-coordinator/internal/buyer/server_test.go` `TestTier2RequireHashVerifiedRoutesOnlyVerified`; `phase7-verify/internal/verify/catalog_check_test.go` `TestCatalogCheckHashMatch`. |
| AC-022-2 | Covered | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotSkippedForNonSettlementCapableModelHash`; `phase4-coordinator/internal/buyer/server_test.go` `TestTier2RequireHashVerifiedUncataloguedReturns503`. |
| AC-022-3 | Covered | `phase4-coordinator/internal/buyer/server_test.go` `TestTier2HashMismatchOnlyReturnsTier2Mismatch`; `phase7-verify/internal/verify/catalog_check_test.go` `TestCatalogCheckModelHashMismatch`. |
| AC-022-4 | Partial | `phase3-binary/Tests/macprovider-cliTests/HTTPServerSwapTests.swift` `testInferenceReturns503WhenDraining`; `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift` `testHTTPHandlerEmitsModelSwapOmissionAudit`; add coordinator-side covered-routing exclusion for loading or draining providers. |
| AC-022-5 | Covered | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts`; `phase4-coordinator/internal/billing/route_snapshot_test.go` `TestInsertRouteSnapshotPersistsCanonicalDigestAndRejectsRewrite`. |
| AC-022-6 | Covered | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts`; `phase4-coordinator/internal/billing/route_snapshot_test.go` `TestRouteSnapshotStrictKeysAndDigestSensitivity`. |
| AC-022-7 | Blocked | Add an enforce-mode expired or unverifiable catalog test proving no final buyer debit and no provider credit. Current catalog freshness tests do not cover SPEC-022 money settlement. |
| AC-022-8 | Covered | `phase4-coordinator/internal/billing/spec022_money_gate_test.go` `TestSPEC022NonStreamingVerifiedReceiptCreatesBuyerFinalityAndProviderPayout` proves an enforce-mode signed, catalog-matching non-streaming receipt on the runtime `spec022-prereq-v0` policy opens verified buyer-debit finality and rewrites an inflated pre-receipt provider credit to the receipt-bound computed amount before payout readiness; `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewaySettlementReconcileFinalizesHeldReservation` proves verified coordinator finality for the same accepted policy creates the final gateway buyer debit. |
| AC-022-9 | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptUnknownFutureVersionNotPayable`; `phase7-verify/internal/verify/settlement_test.go` `TestV03VerifierReportsV04WireReceiptUnknownVersion`; add full no-buyer-debit and no-provider-settlement assertion for v0.3-or-earlier receipts. |
| AC-022-10a | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptV04NegativeFixturesQuarantine`; add full buyer reservation refund and provider-zero assertion. |
| AC-022-10b | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptDeadlineAndReplayMapping`; `phase7-verify/internal/verify/settlement_test.go` `TestVerifySettlementReceiptRejectsReplayContext`; add full refund/provider-zero assertion. |
| AC-022-10c | Partial | `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift` `testV04SignedTuplesCoverTerminalStateMatrix`; `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; add full refund/provider-zero assertion. |
| AC-022-10d | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestSettlementVerifierReceiptKeyIDFixture`; `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift` `testBuildSettlementRejectsWrongReceiptKeyID`; add full refund/provider-zero assertion. |
| AC-022-11 | Partial | `phase7-verify/internal/verify/catalog_check_test.go` `TestCatalogCheckNullHashRequireModelHash`; add end-to-end proof that hashless receipts create no buyer debit, provider credit, earnings visibility, or payout readiness. |
| AC-022-12 | Covered | `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift` `testHTTPStreamingHandlerWritesV04SettlementReceiptTrailer`; `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestStreamingSettlementOutputPersistsOpenAICompatibleSSE`; `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit` and `TestStreamingReceiptHeaderStripped` prove internal streaming settlement trailers carry coordinator finality while buyer-visible SSE remains OpenAI-compatible. |
| AC-022-13 | Partial | `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit` and `TestSPEC022GatewayStreamingNonOKFinalityBoundsHold` prove covered streaming reservations are debited only after verified coordinator finality and remain held/refundable for missing or non-OK finality; add full stream-completion, receipt-arrival, settlement-sweep, and payout-sweep e2e coverage before marking covered. |
| AC-022-14 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops`; `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptDeadlineAndReplayMapping`; `phase5-gateway/cmd/gateway/main_test.go` `TestRunSettlementReconcilerRunsImmediately`; `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewaySettlementReconcileRefundsAndHolds` prove automatic gateway reconciliation can release/refund/hold pending or missing receipt outcomes; add full buyer refund/release plus provider-zero e2e assertion. |
| AC-022-15 | Partial | `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit`; `TestSPEC022GatewayStreamingNonOKFinalityBoundsHold`; `TestStreamingProviderReportedUsageCannotUnderstateObservedOutput` prove streaming charge movement is tied to coordinator finality and bounded observed output usage; add full charged-partial-output receipt-binding e2e with terminal state, delivered prefix, and partial usage. |
| AC-022-16 | Partial | `phase4-coordinator/internal/billing/endpoints_test.go` `TestEarningsEndpointIncludesProviderSettlementReceiptReasonCodes`; D9 provider-credit summary and payout-ready work excludes pending and quarantined SPEC-022 rows from payable views; D14 payout-claim revalidation rejects mutated or source-less settled payout sources; add full SPEC-016 payout-consumption exclusion coverage across pending, quarantined, and recovered rows. |
| AC-022-17 | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptRequiresLedgerUsageAndOutputState`; add direct `zero_settled` impossibility tests for missing, invalid, mismatched, legacy, hashless, and route-snapshot-mismatched receipts. |
| AC-022-18 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit`; add paired observe/enforce test proving observe emits verdict fields without changing money or buyer-facing enforcement claims. |
| AC-022-19 | Blocked | Add explicit `verified_model_settlement` receipt-profile availability validation for all covered modes, including streaming. |
| AC-022-20 | Blocked | Add explicit paid-entrypoint validation proving every covered paid entrypoint can consume the effective policy and produce route snapshots. |
| AC-022-21 | Blocked | Add release gate proving paid direct and legacy entrypoints are compliant, disabled for paid traffic, or excluded and incapable of paid ledger rows. |
| AC-022-22 | Partial | `phase4-coordinator/internal/billing/store_test.go` `TestSnapshotAt_UsesRollbackReloadEffectiveTime`; `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts`; add rollback test proving existing enforce rows retain payout exclusion and pending deadline behavior. |
| AC-022-23 | Partial | D9/D14 coordinator payout tests prove pending, quarantined, source-less, forged, inflated, and post-settlement-mutated payout rows cannot become payable or claimable; `phase4-coordinator/internal/billing/spec022_money_gate_test.go` covers manual ready-row and forged-source rejection; add full inventory and tests for any remaining admin/operator compensation paths. |
| AC-022-24 | Manual gate | No buyer receipt retrieval API is introduced by this branch. Release gate: verify route inventory still exposes no buyer receipt retrieval endpoint; if added, add account-ownership and redaction tests. |
| AC-022-25 | Covered | `phase5-gateway/internal/router/server_test.go` `TestModelsResponseIncludesTier1Disclosure`; `TestModelsDisclosureReflectsTier2HashState`; `phase5-gateway/internal/router/pages_test.go` `TestTier1DisclosureMatchesSpecSection16`. `/v1/models` names included paid entrypoints, states observe mode cannot claim verified integrity, and avoids fully verified language for mixed pools. |
| AC-022-26 | Partial | `phase4-coordinator/internal/billing/store_test.go` `TestRecoverLedger_MissingSnapshotQuarantinesExistingRow`; add direct recovery/backfill test proving missing route snapshots are never synthesized into verified outcomes. |
| AC-022-27 | Partial | `phase4-coordinator/internal/billing/spec022_money_gate_test.go` `TestSPEC022DuplicateVerifiedReceiptAfterSettlementDoesNotDoublePay` and `TestSPEC022ConcurrentSettlementWorkersSettleVerifiedRowOnce` prove duplicate receipt and same-process settlement-worker races do not double-pay after verified settlement; add full stream-completion, receipt-arrival, gateway-reconciliation, and payout-sweep ordering harness. |
| AC-022-28 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestSettlementReceiptPersistsCoordinatorEvidenceForMismatchedSignedReceipt`; add full buyer refund and provider-zero assertion for mid-request warm-swap mismatch. |
| AC-022-29 | Blocked | Add enforce-mode service policy fetch/use failure tests proving paid traffic fails closed or holds pending without legacy settlement fallback. |
| AC-022-30 | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptDeadlineAndReplayMapping`; `phase7-verify/internal/verify/settlement_test.go` `TestVerifySettlementReceiptRejectsReplayContext`; add full money-path assertion proving replay cannot create positive settlement. |
| AC-022-31 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestSettlementReceiptResubmissionCannotChangeClosedOutcome`; `phase4-coordinator/internal/billing/store_test.go` `TestSettlement_Idempotency`; `phase4-coordinator/internal/billing/spec022_money_gate_test.go` `TestSPEC022DuplicateVerifiedReceiptAfterSettlementDoesNotDoublePay`; D13 gateway terminal reservation idempotency proves repeated reconciliation does not create duplicate buyer terminal movement; add one cross-service e2e proving no second buyer debit, provider credit, or payout-ready row from one verified receipt. |
| AC-022-32 | Blocked | Add non-streaming missing-receipt full-path test proving pending, deadline quarantine, buyer release/refund, provider-zero, and no provider-reported or estimated fallback. |
| AC-022-33 | Partial | `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewaySettlementReconcileFinalizesHeldReservation`; `phase5-gateway/cmd/gateway/main_test.go` `TestRunSettlementReconcilerRunsImmediately` prove internal verified coordinator finality can automatically finalize buyer debit without exposing buyer receipt retrieval; D9/D14 coordinator payout evidence covers receipt-bound provider-positive movement; add full gateway/coordinator e2e proving both buyer debit and provider credit from the same verified request. |
| AC-022-34 | Partial | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptDeadlineAndReplayMapping`; `phase4-coordinator/internal/billing/spec015_v04_acceptance_test.go` `TestSPEC015V04AcceptanceCriteria`; add focused catalog-expiry-after-route-time settlement test. |
| AC-022-35 | Manual gate | Same conditional surface as AC-022-24: no buyer receipt retrieval endpoint exists. If added, stranger-account 403, operator access, and metadata visibility tests are required. |
| AC-022-36 | Partial | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestStreamingSettlementOutputPersistsOpenAICompatibleSSE`; `phase5-gateway/internal/router/server_test.go` `TestStreamingReceiptHeaderStripped`; `phase4-coordinator/internal/buyer/server_test.go` `TestHTTPForwardingStripsV04SettlementReceiptFromBuyerResponse`; add stock OpenAI-compatible streaming-client smoke through `[DONE]`. |
| AC-022-37 | Partial | `phase4-coordinator/internal/buyer/server_test.go` `TestTier2RequireHashVerifiedCatalogUnavailableLogsExclusion`; `TestTier2HashMismatchOnlyReturnsTier2Mismatch`; `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotSkippedForNonSettlementCapableModelHash`; add an exhaustive R-2.4 exclusion matrix for stale, empty, invalid, and ambiguous states. |
| AC-022-38 | Covered | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit`; `phase4-coordinator/internal/billing/endpoints_test.go` `TestSettlementReceiptDiagnosticsQueryShapeIsBounded`; `phase4-coordinator/internal/billing/endpoints_test.go` `TestSummaryEndpointIncludesSettlementVerdictCounters`. |
| AC-022-39 | Partial | D13 automatic gateway reconciliation ties buyer debit movement to coordinator receipt verdicts; `phase4-coordinator/internal/billing/spec022_money_gate_test.go` `TestSPEC022PayoutClaimRejectsManualReadyRowWithoutVerifiedSources`, `TestSPEC022PayoutClaimRejectsForgedSourceRows`, `TestSPEC022SettledSourceMoneyFieldsAreImmutable`, and `TestSPEC022SettlementTransitionCannotMutateMoney` prove money-positive payout-ready bypass rows without immutable verified sources cannot be claimed; add compensation-row inventory and equivalent rejection coverage if such paths exist. |
| AC-022-40 | Blocked | Add request-spanning enforce activation test proving pre-activation rows settle under their request-start policy and are not retroactively quarantined. |
| AC-022-41 | Blocked | Add `zero_settled` full-path tests proving buyer release/refund or zero debit, provider-zero, earnings/sweep/payout exclusion, and counter increments. |
| AC-022-42a | Covered | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptV04NegativeFixturesQuarantine`; `phase7-verify/internal/jcs/v04_settlement_fixture_test.go` `TestV04NegativeReceiptFixturesFailExpectedChecks`. |
| AC-022-42b | Covered | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptRequiresLedgerUsageAndOutputState`; `phase7-verify/internal/verify/settlement_test.go` `TestVerifySettlementReceiptRequiresLedgerUsageAndOutputState`. |
| AC-022-43 | Blocked | Add enforce activation failure reporting for each unmet R-1.3 precondition. |
| AC-022-44 | Covered | `phase5-gateway/internal/router/server_test.go` `TestModelsResponseIncludesTier1Disclosure`; SPEC/account/docs/console drift test co-locates the provider-reported-hash caveat with verified-model language. |
| AC-022-45 | Covered | `phase5-gateway/internal/router/server_test.go` `TestUsageIncludesSPEC022SettlementDisclosure`; `phase5-gateway/internal/router/pages_test.go` `TestTier1DisclosureMatchesSpecSection16`. |
| AC-022-46 | Covered | `phase5-gateway/internal/router/server_test.go` `TestUsageIncludesSPEC022SettlementDisclosure`; docs/account/console disclosure text states receipt-bound prefix and partial usage are required. |
| AC-022-47 | Partial | `phase5-gateway/internal/router/server_test.go` `TestSPEC022GatewaySettlementReconcileRefundsAndHolds` and D13 automatic reconciler tests prove terminal SPEC-022 reconciliation clears, refunds, or preserves bounded holds for pending outcomes; add SPEC-006 concurrent agentic reservation test proving no stale holds under concurrent terminal rows. Existing primitive: `phase5-gateway/internal/storage/sqlite/store_test.go` `TestConcurrentQuotaReservationsNoOverspend`. |
| AC-022-48 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops`; `TestSettlementReceiptReceivedAfterDeadlineQuarantinesEvenWithValidHeader`; add full buyer refund/release, provider-zero, and payout-absence assertion for late valid receipts. |
| AC-022-49 | Blocked | Add receipt-aware streaming failover harness proving per-attempt debit/settlement, sum of verified prefixes, no unverified charge, and no overlapping credit. |
| AC-022-50a | Partial | `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift` `testV04SignedTuplesCoverTerminalStateMatrix`; add chargeability settlement assertion. |
| AC-022-50b | Partial | `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; `phase5-gateway/internal/router/streaming_structured_output_test.go` `TestStreamingStructuredOutputTerminalSSEErrorPassesThroughWithoutOKSettlement`; add chargeability settlement assertion. |
| AC-022-50c | Partial | `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; `phase5-gateway/internal/router/server_test.go` `TestStreamingReadErrorAfterBuyerCancelSettlesClientDisconnect`; add chargeability settlement assertion. |
| AC-022-50d | Partial | `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; `phase5-gateway/internal/router/streaming_structured_output_test.go` `TestStreamingStructuredOutputGatewayTimeoutEmitsProviderTimeout`; add chargeability settlement assertion. |
| AC-022-50e | Partial | `phase4-coordinator/internal/buyer/settlement_output_test.go` `TestTerminalStateFromAttemptCoversReceiptTerminalStates`; `phase5-gateway/internal/router/server_test.go` `TestStreamingScannerErrorSettlesStreamTruncated`; add chargeability settlement assertion. |
| AC-022-51 | Blocked | Add enforce activation refusal when any R-5.5 streaming terminal state lacks receipt or settlement chargeability classification. |
| AC-022-52 | Partial | `phase4-coordinator/internal/billing/spec022_money_gate_test.go` `TestSPEC022ConcurrentSettlementWorkersSettleVerifiedRowOnce` proves same-process settlement workers create one verified provider settlement path; D13 gateway reconciliation proves terminal reservation finalization/refund is idempotent for repeated worker runs; add true multi-worker/full-path harness proving one buyer debit, one provider credit, and at most one payout-ready insertion for one verified row. |
| AC-022-53 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops`; add rollback test proving deadline-quarantined rows remain non-payable after enforce-to-observe rollback. |
| AC-022-54 | Covered | `phase4-coordinator/internal/billing/settlement_verifier_test.go` `TestVerifySettlementReceiptAcceptsCoordinatorObservedAttemptOutputRow`; `phase5-gateway/internal/router/server_test.go` `TestStreamingProviderReportedUsageCannotUnderstateObservedOutput`; `TestStreamingUnderreportedUsageWithHighProviderPromptFallsBackToGatewayEstimate`. |
| AC-022-55 | Covered | `phase5-gateway/internal/router/server_test.go` `TestModelsResponseIncludesTier1Disclosure`; `phase5-gateway/internal/router/pages_test.go` `TestTier1DisclosureMatchesSpecSection16`. |
| AC-022-56 | Covered | `phase5-gateway/internal/router/server_test.go` `TestUsageIncludesSPEC022SettlementDisclosure`; `/v1/usage` now returns `settlement_disclosure.pending_reservation`. |
| AC-022-57 | Partial | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts`; `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit`; D9 route-snapshot policy mode/version/hash recovery and D14 immutable settled source linkage strengthen request-start policy preservation; add full settlement and rollback tests proving every covered ledger row reads immutable request-start policy data. |
| AC-022-58 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestSettlementReceiptResubmissionCannotChangeClosedOutcome`; add bad-then-good still-open receipt test proving first terminal verifier outcome remains authoritative. |
| AC-022-59 | Partial | `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestSettlementReceiptResubmissionCannotChangeClosedOutcome`; `phase7-verify/internal/jcs/v04_settlement_fixture_test.go` `TestV04ReceiptTupleRangesDoNotOverlapWithinRequest`; add still-open different-usage-or-hash replay test. |
| AC-022-60 | Blocked | Add pre-enforce payout-ready classification tests excluding legacy rows from SPEC-022 verified counters and enforcement evidence. |
| AC-022-61 | Partial | `phase4-coordinator/internal/buyer/route_snapshot_test.go` `TestSettlementOutputUsesBoundedTerminalTimestampHeader`; `phase4-coordinator/internal/billing/settlement_receipts_test.go` `TestSettlementReceiptRejectsCallerControlledReceiveTime`; add normal plus every partial terminal-state deadline matrix. |
| AC-022-62 | Blocked | Add receipt-aware failover test for buyer-cancel, gateway-timeout, and upstream-disconnect final attempts with no overlapping charge or credit. |
| AC-022-63 | Partial | D10-D13 gateway reconciliation proves verified buyer debit uses coordinator-observed usage/finality rather than provider-signed usage alone; D14 payout-claim revalidation proves provider-positive payout consumption depends on immutable verified source rows linked to the same receipt-bound settlement; add normal-completion cross-service e2e proving buyer debit and provider credit derive from the same canonical request/output evidence. |
| AC-022-64 | Covered | `phase5-gateway/internal/router/pages_test.go` `TestProviderPartnerDocsIncludeLateReceiptDeadlineDisclosure`; `phase3-binary/dist/README-partner.md` states receipts after `pending_deadline_seconds` are non-settling and non-recoverable unless a future exception spec changes the rule. |

## Tests

Validated with:

```bash
cd phase4-coordinator && go test -count=1 ./internal/billing -run TestSPEC022D8AcceptanceCoverageMapIncludesAllACs
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase7-verify && go test ./...
cd phase3-binary && swift test
```

`phase3-binary && swift test` passed in this D8 run: 695 tests, 7 skipped,
0 failures. The full sweep must be rerun after the blocked ACs are implemented.

## Audit

Codex code, security, and architecture audit lanes are required after D8 edits
and any blocked-gap implementation patches. Claude lanes remain deferred until
the full implementation is complete, per current instruction.
