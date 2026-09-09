# BYOM v0.1 Disablement & Rollback Map

**Epic:** #1240 · **Gate:** #1248 (require evidence, rollout, rollback, and
old-client compatibility before promotion).

This is the concrete answer #1248 demands: for every provider-visible and
buyer-facing BYOM surface, the exact switch that turns it off **without deleting
provider state**. "Rollback exists" is not enough — each row names the switch.

## Design fact: BYOM v0.1 is fail-closed by construction

There is **no** single BYOM feature flag, by design. v0.1 ships discovery +
evaluation + honest non-earning disclosure + a coordinator settlement-evidence
gate, and **no v0.1 promotion path emits a settlement-capable row**. The
money-path backstops are fail-closed **by construction** — paid routing is gated
on a settlement-binding predicate (`settlement_capable` state + full trusted
catalog binding + coordinator event id), not a single hardcoded return that a
later change might flip. The state machine does allow a `settlement_capable`
row to route and credit under billing `enforce` mode with valid SPEC-022
receipts (`route_snapshot_test.go:TestBYOMSettlementCapableBindsAdmissionEventIntoRouteSnapshot`),
but providers can only reach `offer_submitted`/`withdrawn`, and no v0.1
coordinator path mints the trusted catalog binding — so the disablement points
below are defense-in-depth for individual surfaces, not the thing standing
between BYOM and provider payouts.

## Disablement matrix (#1248, ten rows)

Every row names the switch, its default, and the automated proof — or an
explicit not-applicable reason. Test references are `file:testName`.

| # | Surface | Switch (no state loss) | Default | Proof / N-A reason |
|---|---|---|---|---|
| 1 | **Discovery** | Provider-local only. `models discover` never contacts the coordinator: candidates stay `admission_state_source: local_default`, discovery is read-only (it does not even provision the local namespace). `--skip-ollama` drops the loopback adapter; the Malibu surface is hidden by withdrawing the capability manifest entry; withholding a CLI release withholds the command. | on, local-only, no coordinator mutation | `phase3-binary/Tests/macprovider-cliTests/BYOMDiscoveryTests.swift:testDiscoverIsReadOnlyWhenNamespaceMissing`, `:testDiscoveryDoesNotMutateModelCache`, `:testInvalidNamespacePermissionsKeepCandidateLocalOnly` |
| 2 | **Evaluation** | `models evaluate` is a CLI-owned local harness; not running it changes nothing. It mutates no serving config, no model cache, and no coordinator state, so disabling it deletes neither the candidate namespace nor model artifacts. | on, no mutation | `phase3-binary/Tests/macprovider-cliTests/BYOMEvaluationTests.swift:testEvaluateCommandRunsHermeticLoopbackRuntimeWithoutMutation`, `:testEvaluateMLXCandidateBlocksWithoutCacheMutation`, `:testProvisioningDoesNotChmodExistingParentDirectory` |
| 3 | **Offer submit** | **`MACPROVIDER_MODEL_ADMISSION_SUBMISSIONS=disabled`** on the coordinator process (wired as `providerws.WithModelAdmissionSubmissionsDisabled(true)`, `phase4-coordinator/cmd/coordinator/main.go`). New `POST /v1/provider/model-admission/offers` is rejected `503 {"error":{"code":"submissions_disabled"}}` before any parse or append; **no admission event is written and nothing is deleted**. `GET .../status` readback and `POST .../withdrawals` for existing offers keep working. Accepted values are unset/`enabled`/`disabled`; any other value refuses to boot. Provider CLI maps the rejection to the existing `wait_for_coordinator` guidance. | `enabled` (current behaviour) | `phase4-coordinator/cmd/coordinator/model_admission_submissions_test.go:TestModelAdmissionSubmissionsDisabledParsesPolicyValues` (env parser: unset/`enabled`/`disabled`, case/whitespace-insensitive, unknown values refuse boot); `phase4-coordinator/internal/ws/model_admission_disablement_test.go:TestModelAdmissionSubmissionsDisabledRejectsSubmitAndPreservesReadback` (memory + SQLite parity), `:TestModelAdmissionSubmissionsEnabledByDefault`; `phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift:testOfferSubmitRejectedByDisabledCoordinatorMapsToWaitForCoordinator` |
| 4 | **Synthetic probe** | **Not applicable in v0.1: no probe dispatch exists.** `sandbox_probe_only` appears only as a SPEC-047-R001 state-machine label and in `modelAdmissionAllowedNextStates` (`phase4-coordinator/internal/ws/model_admission.go`); grepping the coordinator and gateway for probe dispatch keyed on admission state returns nothing. The SPEC-032 canary prober is unrelated to BYOM admission and is not triggered by admission state. Nothing to disable; offer status storage is already independent. | n/a (unimplemented) | N-A verified by grep: `sandbox_probe_only` has no dispatch site; `SyntheticProbe`/`synthetic_probe` absent from `phase4-coordinator` and `phase5-gateway` |
| 5 | **Experimental visibility** | **Not applicable in v0.1: no opt-in surface exists.** Default buyer visibility is off and there is no experimental/unpriced buyer opt-in to disable — no BYOM experimental/unpriced visibility dispatch or opt-in site exists: `network_visible_unpriced` appears only in admission state/guidance code and tests, and the only `experimental` references under `phase5-gateway/internal` are the unrelated Anthropic Messages facade notes in `router/templates/docs.md`. The default-off half of the row is enforced by the routing gate in row 6. | off, no opt-in surface | Default-off proven by `phase4-coordinator/internal/buyer/route_snapshot_test.go:TestBYOMNonSettlementStatesAreHiddenFromDefaultPaidModelsAndRouting` (includes `network_visible_unpriced`); N-A for the opt-in half verified by grep |
| 6 | **Routing** | `ModelAdmissionDefaultPaidRoutingEligible` (`phase4-coordinator/internal/ws/model_admission.go`) is a **settlement-binding predicate**, not a hardcoded return: it delegates to `ModelAdmissionSettlementBindingForRouteSnapshot` and is true only when the event carries a full settlement binding (`settlement_capable` + non-empty `catalog_model_key` + `coordinator_event_id`, matched across every predicate field). Uncertain admission state, a missing store, or a catalog-key mismatch fails closed. Hard-off for the whole admission surface: deploy without `providerws.WithModelAdmissionStore` (loses readback — prefer row 3's switch). | fail-closed; no BYOM v0.1 row satisfies the predicate | `phase4-coordinator/internal/buyer/route_snapshot_test.go:TestBYOMNonSettlementStatesAreHiddenFromDefaultPaidModelsAndRouting`, `:TestBYOMCatalogPricedIsHiddenFromDefaultPaidModelsAndRouting`, `:TestBYOMCatalogKeyMismatchFailsClosed`, `:TestBYOMHiddenProviderDoesNotShadowModelClassAlias` |
| 7 | **Settlement** | Billing `verified_model_settlement_mode` read by `Server.settlementEnforceMode()` (`phase4-coordinator/internal/buyer/server.go`): `observe` or a nil billing store ⇒ no settlement side effects. Positive provider credit and final buyer debit additionally require the settlement-capable gate plus SPEC-022 receipt checks (valid receipt key, matching catalog key), each fail-closed. | `observe` (never `enforce` unless configured) | `phase4-coordinator/internal/billing/account_scope_test.go:TestVerifiedModelSettlementModeDefaultsObserve`; `phase4-coordinator/internal/buyer/route_snapshot_test.go:TestBYOMSettlementCapableRequiresValidReceiptKeyBeforeRouting`, `:TestBYOMSettlementCapableBindsAdmissionEventIntoRouteSnapshot`, `:TestBYOMCatalogKeyMismatchFailsClosed` |
| 8 | **Economics projection** | Rate/payout fields are null unless `rate_card_source: live_signed` + a fresh signed rate card + a coordinator-bound trusted catalog identity all hold. Revoke or expire the signed rate card, or withhold the coordinator admission status, and rows degrade to `economics_state: blocked` with null money fields. | null/unavailable without trusted inputs | `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift:testLocalOnlyCandidateEncodesExplicitNullMoneyFields` (no coordinator status at all), `:testFallbackAndStaleRateCardsKeepMoneyFieldsNull`, `:testSettlementCapableRequiresCoordinatorSettlementState`, `:testFeedIntegrityWarningsBlockEconomicsEvenWithCoordinatorPricing` |
| 9 | **Malibu app** | Checked-in capability manifest `phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json`. Remove/withhold `model_catalog_economics_v1` (and `model_ready_switch_v1`) and the app falls back to its existing static `models list` management. No provider state touched. | on only if the manifest advertises the caps **and** a fresh provider observation agrees | `phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift:testRefreshFallsBackToLegacyListWhenCatalogEconomicsCapabilityMissing`, `:testLegacyFallbackCancelsPreviousCatalogProjectionExpiry` |
| 10 | **`openai_compatible_loopback` adapter** (#1453 slice 1) | Off unless the operator names an origin: `models discover/evaluate/offer/admission ...` take **`--openai-compatible-origin`** with **no default**, so omitting it leaves the adapter unattempted (`adapters[].status: not_configured`, zero requests dispatched). **`--skip-openai-compatible`** suppresses it even when an origin is configured. Both are read-only client-side switches: the adapter persists nothing, holds no credential, and its candidates are `identity_state: opaque_endpoint` / `admission_state: local_only`, which `BYOMOfferSubmissionBuilder.canSubmit` refuses, so no coordinator state exists to lose. | off (no default origin) | `phase3-binary/Tests/macprovider-cliTests/BYOMDiscoveryTests.swift:testOpenAICompatibleAdapterIsNotAttemptedWithoutOperatorOrigin`, `:testOpenAICompatibleAdapterEmitsOpaqueEndpointCandidate`, `:testOpenAICompatibleAdapterRejectsNonLoopbackOriginBeforeDispatch`, `:testOpenAICompatibleOfferDryRunClaimsNoCatalogPath`; `phase3-binary/Tests/macprovider-cliTests/BYOMEvaluationTests.swift:testEvaluateOpaqueOpenAICompatibleCandidateStaysNonEarning` |

Supporting client-side notes for rows 1-3: the provider CLI BYOM commands
(`models discover/evaluate/offer/admission ...`) are client-side and harmless
against a coordinator that does not accept admission. Production coordinator
URLs are HTTPS/WSS-only; `MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR`
(default off) is E2E-only. To withhold the commands from the fleet, do not cut a
CLI release containing them — they stay merged-but-unreleased.

## Rollback of a bad promotion

- **Coordinator (Go):** redeploy the prior tagged coordinator build. The
  admission store is append-only and additive; rolling back the binary leaves
  provider tokens and any recorded admission events intact. No schema migration
  is destructive.
- **Provider CLI / Malibu.app (fleet):** a BYOM release is a normal
  Malibu.app + `macprovider-cli` release cut and rolls back the normal way — cut
  a new release from the prior stable tag; do **not** patch an immutable release
  in place. Follow `docs/runbooks/provider-cli-release-verification.md` (SHA
  byte-identity between the app-embedded and standalone `macprovider-cli`,
  updater path from the previous stable, `release-builds.tsv` row). The
  fleet-updater hazard here is standard release safety, not BYOM: BYOM enables no
  earning, so a rollback loses no money-path state.
- **Fastest partial kill without a release:** set
  `MACPROVIDER_MODEL_ADMISSION_SUBMISSIONS=disabled` and restart the coordinator
  to stop new offers while keeping status readback and withdrawals live (row 3),
  withdraw the Malibu capability (manifest) to hide the app UI, and keep
  `verified_model_settlement_mode` off — all three are config/resource changes,
  no fleet update required.

## Old-client compatibility

- Pre-BYOM CLIs simply do not send admission offers; the coordinator endpoints
  are additive and unused by them.
- The Malibu economics projection is a closed, versioned schema
  (`model_catalog_economics.v1`); older apps that do not advertise the capability
  never fetch or render it.
- No existing provider/billing schema field changed meaning; admission storage is
  keyed on `(provider_id, candidate_id)`, separate from existing identities
  (#1247).

### Old-client compatibility - tests

@SmtTheSE flagged in #1248 that the candidate E2E exercised only the
current-tree CLI and app. These automated tests close that gap in both
directions.

**Pre-BYOM provider against a BYOM coordinator**

- `phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:TestPreBYOMProviderHelloAndHeartbeatStayPooledWithModelAdmissionStore`
  - a hello/heartbeat with no BYOM fields is admitted and pooled with the
    admission store wired, and acquires no BYOM identity fields.
- `phase4-coordinator/internal/buyer/byom_old_client_compat_test.go:TestPreBYOMProviderStaysListedAndRoutableWithModelAdmissionStoreWired`
  - the same provider stays in `/v1/models`, is reached by default paid routing
    under `enforce`, and still writes a route snapshot: BYOM gating never
    captures non-BYOM supply.
- `phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:TestModelAdmissionStatusForPreBYOMProviderReturnsNotOffered`
  - admission status readback for a provider that never offered returns the
    `not_offered` shape with no fabricated served model ref, catalog key, or
    event id - not an error.
- `phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:TestSQLiteModelAdmissionSchemaInitIsAdditiveOnPreBYOMDatabase`
  - the admission schema init on a database created before the BYOM tables
    existed creates them without touching `request_log` or `provider_tokens`
    rows, is idempotent on re-run, and leaves pre-existing provider tokens
    validating.

**Current CLI/app against a pre-BYOM coordinator**

- `phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift:testAdmissionStatusAgainstPreBYOMCoordinatorFailsClosedWithoutFabricatingState`
  - 404/405 (no admission endpoints) and an unknown 200 schema both fail closed;
    the CLI never fabricates a coordinator admission state and the operator is
    pointed at `local_default` / `wait_for_coordinator`.
- `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift:testLocalOnlyCandidateEncodesExplicitNullMoneyFields`
  - with no coordinator admission status available (exactly what a pre-BYOM
    coordinator yields, since `readAdmissionStatuses` drops failed lookups), the
    projection stays `local_default` / `blocked` with null money fields.
- `phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift:testRefreshFallsBackToLegacyListWhenCatalogEconomicsCapabilityMissing`
  - the app falls back to the legacy static `models list` surface when the
    catalog-economics capability is absent (pre-existing coverage, cited not
    duplicated).

## Promotion checklist (closes #1248 + #1240)

1. `make test-byom-e2e` green + the real-Mac candidate E2E green
   (`test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`), evidence captured.
2. Gates #1243–#1247 closed with per-gate evidence.
3. This disablement/rollback map reviewed and current.
4. Coordinator admission endpoints deployed from a tag (Go).
5. Malibu.app + CLI release cut passing provider-CLI-release-verification.
6. Signed journey evidence where the governance process requires it:
   `JOURNEY-PROVIDER-BYOM-DISCOVERY` (SPEC-046) and
   `JOURNEY-NETWORK-MODEL-ADMISSION` (SPEC-047), captured, built, signed,
   preflighted, and promoted through
   `docs/runbooks/byom-journey-evidence.md`. Signing needs the operator
   acceptance key; conformance rows change only via
   `scripts/promote-signed-journey-result.py`, never by hand.
