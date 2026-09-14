# Build 1 reconciliation PRD and implementation plan — origin/main 1d2 r2

Status: **PROPOSED; not implementation authorization**. No source or test
implementation may begin until an independent GPT-5.6 Sol review of this exact
document and `test-spec-origin-main-1d2-reconciliation-r2.md` reports zero
Critical, High, and Medium findings.

Date: 2026-09-11

Scope: Product Build 1 — Self-Service Model Supply

Repository/base: `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`, tree
`39270b08dee665a298e3a67580b127d9368e0f65`.

Frozen source worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`,
branch `codex/product-build-1`, HEAD
`914f7cafcdbcfc1805a10f4f34167218341d5587`, dirty and two commits behind the
reviewed base when this revision was written.

Frozen planning inputs:

| Input | SHA-256 | Disposition |
|---|---|---|
| `origin-main-1d2-impact-sol.md` | `8541a4e495b90d047da1cbe8e049f79a3fcd28810368e6a7f4944739ba75c745` | Current-state evidence; its R4 path table is corrected by this revision. |
| `origin-main-1d2-reconciliation-plan-r1.md` | `0e717a9d9435394b345da7a739a71cb3fb2156ca7b33116f95b4a4e2925d5335` | Superseded. |
| `test-spec-origin-main-1d2-reconciliation-r1.md` | `7d2d675e110b4d3ee351e2aac84926329603797d09586b4d33bd8df553ad5eb2` | Superseded. |
| `reviews/origin-main-1d2-reconciliation-plan-r1-sol.md` | `b88eec568bec45bed08946131f2649fb55d5d2fb32c6dfb98b21fe00eedbe87b` | Failed: 0 Critical / 3 High / 4 Medium. |

The historical roadmap was available at
`/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`; its
baseline `422fc2f13fc62c1ff8987522f822d9ef856e4a96` is historical context only.
No `d-inference` source was inspected.

## Product outcome and truthful journeys

Build 1 lets a provider use shipped CLI and Malibu.app actions to discover one
supported primary MLX model, verify its release-bound artifact source, see its
measured positive download size, prepare it without disturbing the incumbent,
adopt it explicitly, submit and inspect an admission offer, and serve a request
only after coordinator and operator authority make that exact model member
settlement-capable. The resulting request is priced under the exact
coordinator-resolved catalog model key and can be read back as receipt pending,
verified request settlement with receipt-bound provider credits recorded,
quarantined, or zero-settled. This request settlement is not weekly ledger
batching, financial withdrawal, or payout.

The supported journey is:

1. **Discover.** A verified live feed, or a release-compatible compiled
   fallback, identifies one exact candidate row and primary MLX artifact. The UI
   shows signer, release, freshness, artifact identity, catalog economics, and
   authenticated `size_bytes > 0`. Missing/invalid size is browse-only and the
   prepare action is disabled.
2. **Prepare.** Confirmation repeats the exact authenticated byte count. The
   transaction reserves space, downloads to owned staging, enforces the byte
   ceiling while streaming, verifies full bytes, and atomically publishes a
   durable artifact. Preparation does not change the active model or admission.
3. **Cancel or recover.** Before the publication commit, cancellation removes
   only owned staging and preserves the incumbent. After the commit it returns
   `too_late` and reconciles the prepared inactive artifact. Restart follows
   journal and filesystem truth.
4. **Adopt.** Explicit activation revalidates the prepared artifact and uses the
   existing drain/swap/rollback protocol. No network download is hidden in the
   adoption path.
5. **Offer and wait.** The provider signs the offer. Synthetic probing remains
   bounded at `network_admitted_unsettled`. Provider readiness is read from a
   versioned, authenticated, candidate-scoped coordinator projection. It can
   truthfully show sanitized pending-second-operator state without exposing
   operator identity or treating pending as a positive event.
6. **Operator decision.** Positive transitions pass a closed transition service
   whose production persistence API cannot be called with a free-form positive
   state. `settlement_capable` consumes a distinct-actor, unexpired pending
   decision atomically with the appended event after fresh re-evaluation.
7. **Route, price, settle, read.** Before dispatch, the accepted route binding's
   exact `catalog_model_key` selects an exact rate with no alias normalization or
   default fallback. The complete price contract is captured in immutable route
   and ledger evidence. Provider-scoped activity then reports the actual receipt
   and receipt-bound credit outcome, amount, unit, and freshness. Admission
   alone never proves a request settled.

The physical acceptance journey includes real provider actions, two operator
actions, actual MLX inference on a physical Mac, immutable receipt persistence,
one verified receipt-bound credit reconciliation, and provider-visible readback. Local fixtures cannot
qualify it.

## Current implementation classification at 1d2c930

| Roadmap outcome | State | Current code evidence | R2 disposition |
|---|---|---|---|
| Signed artifact-feed production/distribution | Landed | `buyer/catalog_artifacts_feed.go`, `buyer/autotune_feeds.go`, release scripts | Preserve and rerun producer/server/release negatives. |
| Verified provider consumption | Missing on main; dirty implementation unaccepted | Swift `AutotuneArtifactFeed`, `AutotuneRecommend`, `BYOMDiscovery` | Reconcile after gates; no invalid-response fallback promotion. |
| Durable preparation/adoption | Missing on main; dirty implementation and rejected R4 dependency exist | Swift durable store, transaction files, command/app bridge | Fix and approve R4 first, then replay bounded provider slices. |
| Coordinator artifact/model identity | Substantially landed | `artifactidentity.Index`, `releaseSnapshotState`, `matchModelAdmissionOffer`, route guard | Reuse as the only network identity authority. |
| Positive admission/dual control | Handler path landed; store boundary incomplete | `model_admission_operator.go`; generic decision append remains callable in memory/SQLite stores | Replace generic positive persistence access with the closed transition service in this plan. |
| Exact catalog-key pricing | **Partial/missing on money path** | Route carries `ModelAdmissionCatalogModelKey`, but `buyer/billing_recorder.go` and `billing/hotpath.go` rate `row.Model` | Add an immutable pre-dispatch BYOM price contract and fail closed on missing/disagreeing authority. |
| Provider readiness/settlement read | **Missing** | v1 admission status exposes only latest event; settlement finality is buyer/internal and amount-free | Add sanitized readiness v2 and provider-scoped settlement activity v1. |
| Executable provider UX | Partial on main; dirty implementation unaccepted | `ModelCatalogEconomics`, `ModelsSubcommand`, Malibu model management | Compose only authoritative sources; no operator buttons or guessed paid state. |
| Physical prepare-to-settle | Blocked/unproven | No fresh signed-feed → physical MLX → settlement artifact | Remains a named qualification blocker until executed. |

## R1 finding resolutions

| R1 finding | Required R2 correction | Plan/test closure |
|---|---|---|
| H1 authoritative pricing | Price new candidate-bound BYOM routes only from the coordinator-resolved exact catalog key and freeze every economic input before dispatch. | Clauses 5–8; Phase 5; T13–T14 and T21. |
| H2 positive-state origin | Make a closed authenticated transition service the only positive-state persistence caller and consume dual-control approval atomically in both stores. | Clauses 3–4; Phase 4; T09–T12. |
| H3 provider-visible truth | Add candidate-scoped sanitized readiness and provider-scoped receipt/credit activity; keep request settlement distinct from payout or financial withdrawal. | Clauses 10–11 and 15; Phases 6–7; T15–T17 and T21. |
| M1 R4 inventory | Freeze the actual twelve-file executable-target closure and require final approved R4 plan, implementation, and audit evidence. | Corrected manifest; Phase 2; T19. |
| M2 unknown size | Permit preparation only for authenticated signed-feed integer `size_bytes > 0`; unknown size stays browse-only. | Clause 12; Phase 3; T04 and T06–T07. |
| M3 replay semantics | Separate byte-identical lost-response replay from an explicit fresh bounded re-evaluation. | Clause 13; Phases 3–4; T11 and T21. |
| M4 moving slice 5 | Revalidate origin and slice 5 at every planning, overlapping-write, audit, fix, and PR boundary; stop and reopen material changes. | Active-work checkpoints; T01 and T20. |

## Normative contracts

The reconciliation preserves SPEC-010 v1.8 and SPEC-047 v0.1.5 at the base and
is governed by SPEC-023, SPEC-044, SPEC-022, SPEC-005, SPEC-011, SPEC-001, and
BUILD_SPEC_953. Changes to positive transition APIs, provider readiness,
provider settlement activity, or price evidence require the narrow successor
SPEC versions and governance selectors that apply after current-main and active
slice-5 reconciliation. The exact version is never guessed in advance.

The following clauses are mandatory:

1. Provider assertions, local preparation, adoption, benchmark results, signed
   offers, and probe success cannot create `catalog_priced` or
   `settlement_capable`, trusted identity, or price authority.
2. Synthetic probing stops at `network_admitted_unsettled`.
3. Positive persistence is reachable only through a closed operator transition
   service after named-operator authentication. The raw memory/SQLite append is
   private to that service. Provider offer, withdrawal, probe, lifecycle drift,
   operator request, and operator approval commands each have a closed target
   and reason set; no production method accepts a caller-supplied arbitrary
   positive state.
4. The operator service accepts an authenticated principal type that cannot be
   constructed outside the auth package. It re-evaluates head, session,
   release, member, key, and catalog predicates. A settlement approval performs
   pending lookup, distinct-principal check, expiry/invalidation check, event
   append, and pending consumption in one memory critical section or one SQLite
   transaction. Lost responses replay the stored result; restart cannot reopen a
   consumed approval.
5. Coordinator release/member matching resolves `catalog_model_key`. For a BYOM
   route, that exact string is the only pricing key. Lookup is exact and requires
   a present explicit rate-card entry; normalization, request model, provider
   model, artifact ID/hash, row hash, and `default` cannot substitute.
6. Before provider dispatch, the immutable route snapshot captures a versioned
   `byom_price_contract.v1`: exact billing model key; config snapshot id and
   config hash; formula version; unit `credits_per_million_tokens`; prompt,
   prompt-cache-hit, and completion rates; global multiplier; provider share;
   and `max_billable_tokens`. The contract digest is in the route digest. New
   BYOM ledger rows repeat its key/digest and computed inputs. Hot-path,
   recovery, receipt recomputation, reconciliation, and replay use that frozen
   contract and fail closed on disagreement. They do not call `RateFor` or any
   current config/feed accessor for a contract-bearing row.
7. Non-BYOM and historical rows retain their current pricing behavior. No
   existing route, receipt, or ledger row is rewritten or backfilled with
   invented authority. New BYOM candidate-bound rows without a complete price
   contract are ineligible before dispatch.
8. New dispatch uses live release/provider/decision checks. After route and
   billing evidence are inserted, delayed receipt settlement uses immutable
   evidence and never mutable current feed, keyring, catalog, session, or rate
   data.
9. Historical no-extension and exact c944 six-field route representations keep
   byte-identical decoding/digests, including
   `artifact_candidate_catalog_sha256`. The abandoned dirty 24-field authority
   envelope is not emitted or migrated.
10. Existing `GET /v1/provider/model-admission/status` and
    `model_admission_status.v1` remain byte/schema compatible. New
    `GET /v1/provider/model-admission/readiness?candidate_id=<id>` returns closed
    `model_admission_readiness.v2` under the existing read-only provider-token
    authentication and exact candidate scope. The exact top-level fields are
    `schema`, `generated_at`, `cli_version`, `provider_id`, `candidate_id`,
    `served_model_ref`, `catalog_model_key`, `admission_state`,
    `admission_state_source`, `coordinator_event_id`, `state_observed_at`,
    `approval_state`, `approval_expires_at`, `provider_guidance`, and `warnings`.
    Nullable values are present as JSON null, unknown fields and duplicate keys
    are rejected by clients, and the server emits no additional fields without a
    new schema. One store snapshot returns the latest event plus
    sanitized approval state: `not_pending`, `awaiting_second_operator`,
    `operator_review_expired`, `operator_review_invalidated`, or `unknown`;
    pending is reported only when unconsumed, uninvalidated, unexpired, exact
    candidate/tuple, and evaluated-head equal. The response may expose expiry,
    but never pending ID, request digest, actor, credential, operator reason, or
    approval material. Expired/invalidated are sanitized terminal facts for the
    provider's own candidate and carry no actor/reason. Consumed state is
    represented by the resulting event; expired/revoked/stale state cannot
    remain pending. Store/auth failure returns a closed typed HTTP error and the
    UI maps it to unknown; the success schema never guesses.
11. New
    `GET /v1/provider/model-supply/activity?candidate_id=<optional>&after_id=<optional>&through_id=<required-with-after_id>&limit=<1..100>`
    is a read-only provider-token endpoint over billing-owned route, verdict,
    and ledger rows. It returns closed `provider_model_supply_activity.v1` with
    top-level fields `schema`, `generated_at`, `provider_id`, `entries`,
    `next_after_id`, `observed_through_id`, and `warnings`. Each entry has exactly
    `activity_id`, `request_id`, `attempt_n`, `candidate_id`,
    `catalog_model_key`, `byom_price_contract_digest`, `settlement_state`,
    `receipt_result`, `reason_code`, `provider_credits`, `credit_unit`,
    `terminal_state`, `receipt_observed_at`, and `credit_updated_at`. The unit is
    exactly `credits`; nullable timestamps are explicit null. `provider_credits`
    is JSON null while receipt/credit reconciliation is open and a non-negative
    integer only for a closed terminal state. `activity_id` is
    the immutable `settlement_route_snapshots.id`, so a route is visible as
    pending even before any verdict exists. It uses stable descending
    `(activity_id)` keyset pagination, caps limit at 100, freezes
    `observed_through_id` on the first page for a coherent traversal, and filters
    by the token's provider ID and optional candidate before pagination. Cursor
    use on later pages must repeat the frozen watermark. It excludes account
    scope, buyer identity, prompts/outputs,
    receipt bytes, signatures, paths, operator data, and payout claims.
    `settled_verified` requires both a closed valid verified receipt and the
    matching ledger credit reconciled to receipt-bound usage under the immutable
    price contract. The weekly batching `settled` and `settlement_id` fields are
    not exposed or required. All other combinations render pending,
    quarantined, zero-settled, or inconsistent/unavailable; none renders paid or
    withdrawable. Missing auth is 401, disabled/unavailable token authority or
    store is 503, invalid candidate/cursor/limit is 400, and no activity is a
    successful empty page rather than a settlement claim.
12. Actionable preparation requires authenticated signed-feed `size_bytes > 0`
    for live and baked sources. Missing, zero, negative, non-integer, overflow,
    or mismatched size is browse-only/unavailable and creates no transaction,
    staging, reservation, config, journal, or offer mutation. Stream enforcement
    rejects early EOF and any byte past the exact size, regardless of HTTP
    `Content-Length` or chunking.
13. An exact retry replay and a fresh re-evaluation are separate operations.
    Transport recovery resends byte-identical signed bytes with the same request
    ID, nonce, idempotency key, timestamp, digest, and signature and receives the
    stored result without a second probe/event. Explicit bounded re-evaluation
    preserves the protected offer tuple but creates fresh request identity,
    timestamp, nonce, idempotency key, and signature and rechecks current
    authority. The local journal records the exact outbound envelope before send
    and the authoritative outcome after response.
14. GGUF retry proof stays private/local, reopens the same no-follow file,
    verifies complete identity plus recomputed digest, and never enters provider
    wire or positive authority. Primary MLX remains the only new preparation
    scope.
15. UI projections never outrank journals, durable artifact state, admission
    event/pending state, immutable price contract, verdict, or ledger. Catalog
    economics, provider readiness, request settlement, and payout are separate.

## Ownership and dependency graph

| Owner | State and mutation boundary |
|---|---|
| Release owner (`ws.releaseSnapshotState`) | Current/compatible catalogs, artifact identity sets, staged Tier2, feed-integrity verdict, monotonic release generation. |
| Admission transition service | Closed command API; sole positive persistence caller; operator evaluation; pending creation/atomic consumption; memory/SQLite equivalence. |
| Admission persistence (private to service) | Immutable events, replay indexes, pending records, expected-head CAS. No externally callable free-form positive append. |
| Provider section / pool | Per-provider serialization, live session epoch, runtime identity, receipt key, installed admission binding. |
| Route owner (`buyer.ModelAdmissionRouteGuard`) | Live pre-dispatch expectation over event, binding, session, member, and release generation. |
| Pricing owner (`billing`) | Exact BYOM rate selection from accepted catalog key; config snapshot; immutable price-contract bytes/digest; ledger computation and replay. |
| Settlement owner (`billing.Store`) | Route snapshot, attempt output, receipt verdict, receipt-bound ledger credit, deduplication, finality, and provider activity read. Weekly payout batching remains outside this read model. |
| Provider artifact owner (Swift store/transaction) | Owned staging, verified durable bytes, prepared/active refs, cancellation and cleanup. It has no coordinator authority. |
| UI projection owner | Capability negotiation and rendering of authoritative CLI/coordinator read models only. |

Coordinator dependency flow:

`signed release` → `releaseSnapshotState` → `signed offer` → `exact member/key
match` → `unsettled probe` → `authenticated operator transition service` →
`distinct approval` → `session binding` → `route guard` → `exact price contract
before dispatch` → `immutable route/ledger` → `receipt verdict` → `verified
receipt-bound credit` → `provider activity read`.

Provider preparation flow remains separate:

`verified feed target with positive size` → `owned staging/reservation` → `exact
byte ceiling and digest` → `durable publication` → `explicit adoption` →
`signed offer`.

## Lock, transaction, and failure graph

1. Preserve the landed provider-section → pool registry → release-read order.
   Release publication completes under its write lock; sweeps start afterward.
2. Operator authentication occurs before admission state locks. Evaluation runs
   through the transition service. Memory uses one store mutex for event plus
   pending mutation; SQLite uses one observed transaction. No pending approval
   is consumed before the event insert is durable.
3. Route selection captures the accepted admission binding and billing config
   snapshot. Exact price resolution occurs before route insertion/dispatch.
   Route insertion does not hold the release lock while doing SQLite I/O and
   retains its landed postcheck. A price failure produces a typed pre-dispatch
   no-charge failure.
4. Receipt settlement and provider activity reads take no release/provider lock
   and call no current feed/config/keyring accessor for a contract-bearing row.
   Activity pagination is a bounded read transaction and cannot mutate receipt,
   ledger, admission, or payout state.
5. Provider readiness reads event and pending state under one memory lock or one
   SQLite read transaction. It does not extend pending expiry or create an
   event.
6. Local preparation follows the separately approved R4 lock/storage design.
   It never holds its journal/control lock across network fetch, child wait, UI
   callback, or coordinator call. Cancellation and cleanup touch only proven
   transaction ownership.

Every material owner, lock order, callback, price-evidence field, or transaction
boundary change reopens the adversarial plan gate.

## Migration and compatibility

1. Freeze the dirty worktree before replay: tracked/untracked SHA-256 manifests,
   private recovery ref, verified bundle outside the repository, exclusion scan,
   and package-lock provenance. Never rebase this dirty worktree in place.
2. Create a fresh hidden worktree and `codex/` branch from exact 1d2 after the
   plan and R4 gates pass. Replay only approved slices with per-slice manifests.
3. Replace the generic positive store contract by a forward-compatible closed
   transition service. Memory and SQLite behavior, restart, exact replay, and
   pending consumption must remain equivalent. Existing immutable event/pending
   rows are retained.
4. Add optional price-contract fields to new route canonical JSON only when a
   current candidate-bound BYOM route is created. Add nullable, forward-only
   direct columns needed for joins/indexes (`model_admission_candidate_id`,
   `billing_model_key`, `byom_price_contract_digest`) and matching ledger
   columns. Existing rows remain NULL and their JSON/digests remain unchanged.
   Never update through the route immutability trigger or synthesize a backfill.
5. Add indexes for provider activity keyset reads on provider/time/id and
   candidate where justified by `EXPLAIN QUERY PLAN`; cap pages at 100 and avoid
   parsing unbounded JSON in the read path.
6. Keep `model_admission_status.v1` unchanged. Advertise readiness v2 and
   settlement-activity v1 as independent capabilities. Old CLI/app versions
   show approval and settlement as unknown/unavailable and never infer them.
7. Preserve no-extension and exact six-field routes; preserve current non-BYOM
   `RateFor` behavior. A rollback disables new provider actions/read capability
   and new BYOM routing before reverting code; stored optional evidence remains
   readable and immutable.
8. Governance begins from the then-current landed SPEC/index files. It uses a
   new forward version only after origin and slice-5 inspection and retains all
   landed selectors.

## Corrected R4 reservation prerequisite manifest

The impact assessment's `Sources/MacProviderCore/LocalModel...` paths do not
exist. The exact current transaction closure is these twelve paths. The first
nine are the rejected R4 implementation snapshot; the last three are unchanged
support/fixture dependencies that must be frozen with it.

| Canonical path | SHA-256 |
|---|---|
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift` | `260ad23c6a845d76c55b63b0098554e61e123bbca284c25dcf3e94298c7529ef` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionFixtureWrites.swift` | `356ea2f3d5efc0f3384953cb08c609a8d4934955a2b18bf184bd59f6706faaee` |

Pinned current artifacts:

| Artifact | SHA-256 | Status |
|---|---|---|
| R4 plan | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` | Earlier plan; implementation later rejected. |
| R4 current-source compatibility review | `d19a8bc39fecb61ad58e073fcbc147bb45e792a977d18b6972780a7e0c1a32e9` | Zero C/H/M before implementation. |
| R4 implementation checkpoint | `1eeef81a89f0ecc0b0340812ec36741469ede98cda0d9d31988560f9782d6167` | 79 targeted passes; not acceptance. |
| R4 code/security/architecture audits | `db50512be6b61a9dc509a5add0d7987bb0d8b69eeb8130cd0f2381cfab77f112`; `c07a7034ed92b9734bc07b8bd4a106cd8aa47e3c05d0ad1d6185b85bad673ec7`; `1250819d1d24351abe55fca163bcfdf962ccd4d403b7810b78de8a9920d25c4e` | Failed with High/Medium findings. |
| R10 correction plan/test/review | `4b82dd1e0fd849f1472fff86e1f5cd8c5f9bd966946c91b21d8951ca5d17c407`; `2f0397aed4699f90a2a75abf6acf63f0d088fdadd00399f969d57913fcdf6168`; `677ee0df66c9d0351c6ab6d9a3b315772686de20109045185bdba3f9edf569af` | Review failed: 6 High / 2 Medium. |

There is no approved post-fix R4 plan, isolated implementation commit/tree, or
zero-finding post-fix audit. That absence is a prerequisite blocker. Before
dependent replay, a future approved R4 record must pin: final plan/test/review
digests; isolated commit and tree; complete transaction-closure path/hash
manifest; targeted command logs; and code/security/architecture audit digests
with zero Critical/High/Medium. Any missing, additional, renamed, or
hash-mismatched `ModelCatalogTransaction*` path fails the gate. The historical
79-test pass cannot pass it.

## Active slice-5 dependency and base checkpoints

At this revision, `/Users/augstar/macprovider-byom-v02-slice5`, branch
`feat/byom-v02-slice5-intake-pipeline`, is unmerged at
`034c9d2e258ae182f3dc0d636b9ec177ecf0defa`, two commits over 1d2. Its committed
diff changes the intake SPEC/governance surface. Its dirty implementation changes
`buyer/server.go`, `config/config.go`, and `stats/rollup/health.go`, and adds
`buyer/intake_hook.go`, `internal/intake/{aggregator.go,aggregator_test.go}`,
`stats/migrations/028_stats_intake_current.up.sql`, `stats/rollup/intake.go`, and
`stats/store/intake.go`. It is external active work and is neither copied nor
treated as landed.

Run `git fetch origin --prune` and record `origin/main`, merge base, slice-5 HEAD,
dirty path/hash manifest, and per-build/cumulative diff manifests at all of these
checkpoints: after recovery Phase 0; immediately before any source replay;
before every normative/governance edit; before each implementation commit that
touches a path changed by main or slice 5; before complete-diff audits; after
audit fixes; and immediately before PR creation or update.

If slice 5 or another relevant mainline change lands at any checkpoint, stop all
source writes, preserve the current integration branch, rebase a fresh
integration worktree onto the new exact base, regenerate per-build and cumulative
manifests, independently inspect the landed semantics, and rerun affected tests.
Any material change to contracts, owners, locks, schemas, pricing, transition
authority, or test strategy reopens this plan gate. Textually clean merges do not
waive semantic review. If slice 5 stays unmerged, record its exact committed and
dirty manifests, keep an explicit dependent branch/PR relationship, and do not
copy its untracked implementation.

## Conflict-path dispositions

| Surface | Required disposition |
|---|---|
| `buyer/autotune_feeds.go`, `tier2/catalog.go`, `ws/release_snapshot.go` | Keep landed coherent release publication and identity sets; no parallel generation owner. |
| `ws/model_admission*.go` | Preserve event/pending bytes and operator semantics, but replace generic positive append exposure with the closed transition service. Delete dirty automatic promotion. |
| `pool/provider.go`, `buyer/model_admission.go`, `buyer/route_snapshot.go` | Preserve session epoch, exact binding, route expectation, compare-and-insert, and postcheck. Add price resolution from the accepted binding only. |
| `buyer/billing_recorder.go`, `billing/hotpath.go`, `billing/recovery.go`, `billing/settlement_receipts.go` | New contract-bearing BYOM rows use exact immutable price evidence; legacy/non-BYOM remains unchanged. |
| `billing/route_snapshot.go`, migrations/endpoints | Preserve old digests; add optional price contract and provider-scoped settlement activity with indexed direct columns. |
| Swift feed/preparation/transaction/app | Replay only approved provider actions, exact positive size, cancellation and authoritative read composition. |
| SPEC/governance files | Start from checkpointed current main, retain landed/slice-5 selectors, and add only reviewed successors. |

## Bounded implementation phases

### Phase 0 — freeze, recovery, and base checkpoint

Freeze writers; create the private recovery ref/bundle/manifests; verify
permissions and exclusions; restore package-lock provenance; run the first
origin/slice-5 checkpoint. Create a fresh integration worktree only after both
plan gates pass.

### Phase 1 — landed baseline and contract tests

Run fresh 1d2 targeted race suites and freeze golden event, pending, route,
six-field evidence, and status-v1 fixtures. Add failing tests for exact catalog
key pricing, direct positive append rejection, readiness v2, settlement activity,
positive size, and retry/re-evaluation separation before implementation.

### Phase 2 — separate R4 corrective prerequisite

Complete the R4 planning loop and isolated implementation/audits under its own
branch and exact twelve-path closure. Reopen this plan if its final architecture
changes preparation ownership, commit point, capacity, cancellation, or recovery.

### Phase 3 — provider feed, storage, preparation, and adoption

Replay signed-feed consumption, durable discovery, exact-size reservation and
stream enforcement, preparation, cancellation, cleanup, adoption, CLI JSON/JSONL,
and retry journal in small provider-only commits. Do not include coordinator
positive promotion.

### Phase 4 — store-enforced admission authority

Introduce the closed transition service and opaque authenticated-principal
boundary. Convert offer/withdraw/probe/drift/operator handlers to closed
commands. Make raw positive append private. Replace direct-positive test setup
with real authenticated endpoints. Prove atomic pending approval in memory and
SQLite, restart, replay, expiry, invalidation, and concurrency.

### Phase 5 — immutable authoritative pricing

Resolve the exact candidate-bound catalog key and explicit rate before dispatch.
Create and digest `byom_price_contract.v1`; persist its direct join columns;
thread it into hot path, receipt synchronization, recovery, and reconciliation.
Fail pre-dispatch on missing/mismatch/default-only rate. Preserve legacy paths
with golden tests and no backfill.

### Phase 6 — provider-visible readiness and settlement activity

Add candidate-scoped readiness v2 and paginated provider settlement activity v1
under existing provider-token auth. Implement consistent snapshots, sanitized
responses, indexes, bounded pagination, freshness watermarks, and no payout
language. Advertise capabilities independently.

### Phase 7 — truthful CLI and Malibu.app composition

Wire prepare/status/cancel/cleanup/adopt/offer/retry/withdraw plus readiness and
settlement activity. Render prepared, active, unsettled, catalog-priced,
awaiting second operator, settlement-capable, request receipt pending, request
settled, quarantined, and unknown independently. Catalog economics do not imply
eligibility. Xcode MalibuTests are required separately from SwiftPM tests.

### Phase 8 — governance, compatibility, and full verification

Run the required base checkpoint, update only required SPEC successors and
selectors, then targeted and broad Swift/Xcode/Go/integration/vet/lint/dist/
governance tests. Three independent GPT-5.6 Sol code, security, and architecture
lanes review the complete rebased diff until zero Critical/High/Medium. Validate
the PR declaration and produce a reviewable PR without merging or deploying.

## Acceptance mapping

| Product claim | Phase | Verification |
|---|---|---|
| Verified release-bound feed/fallback and exact positive size | 3, 7 | T03–T05, T17 |
| Cancellation-safe durable preparation/adoption | 2–3 | T06–T08, T19 |
| Provider cannot mint positive admission | 4 | T09–T12 |
| Sanitized truthful pending/readiness | 6–7 | T10, T15, T17 |
| Exact catalog key and pre-dispatch immutable pricing | 5 | T13–T14, T21 |
| Provider-visible actual request settlement, separate from payout | 6–7 | T13, T16–T17, T21 |
| Corrupt/stale/cross-release/drift/unsupported failures close | 3–7 | T03–T08, T10, T13–T18 |
| Exact replay versus fresh re-evaluation | 3–4 | T07, T10–T11, T17, T21 |
| Current-main/slice-5 compatibility | every boundary | T01, T19–T20 |
| Physical Mac real MLX request settles once | qualification | T22; open until fresh run |

## Observability and recovery

Use bounded reason codes for invalid/stale feed, size unavailable/mismatch/
overflow, space reservation failure, integrity mismatch, cancellation,
`cancel_too_late`, cleanup required, operator review, pending approval, stale
head, unauthorized transition origin, exact replay, fresh re-evaluation,
catalog-key/rate missing, price-contract mismatch, route postcheck failure,
receipt pending/verified/quarantined/zero-settled, and activity unavailable.
Metrics include counts and bounded durations for preparation phases, transition
commands, pending age, pre-dispatch price resolution, contract mismatch,
receipt-verification/credit-reconciliation lag, and activity freshness. IDs may be logged only where already
permitted. Raw feeds/envelopes, local paths/file identity, account scope, buyer
content, credentials, keys, journals, receipt bytes, and payout data are never
logged.

Restart reconciles provider journal/store before actions, and admission
event/pending state before readiness. Exact outbound replay state survives lost
responses. Settlement/recovery follows immutable price/route/ledger evidence.
Unreadable current authority blocks new routes; unreadable activity renders
unknown/unavailable and never settled. Provider activity is read-only and cannot
repair ledger state.

## Hardware and qualification

Physical acceptance requires a suitable Apple Silicon Mac, supported primary
MLX bytes, recorded sanitized chip/RAM/macOS/Swift/MLX/provider versions, valid
signed release/feed/signer, justified Tier2/reference material, isolated
coordinator/gateway/PostgreSQL services, test-scoped provider/buyer/two-operator
identities, and receipt plus ledger evidence. All roots and credentials are
isolated from operator defaults and repository roots.

If any prerequisite is absent, T22 remains **BLOCKED / UNPROVEN**. Swift
fixtures, selected package tests, deterministic providers, and one synthetic
probe do not qualify physical MLX or production. Release signing/notarization,
deployed-service evidence, production enforcement, and economic activation are
separate and remain unauthorized.

## Rollback

Provider rollback disables new action capabilities and retains the incumbent,
verified prepared artifacts, and recoverable journal. Cleanup removes only
owned staging. Coordinator rollback first disables new candidate-bound BYOM
routing/read capability, preserves all immutable events/pending/route/price/
receipt/ledger rows, and leaves old clients on v1/unknown states. Forward
migrations are not destructively reversed. Historical and non-BYOM pricing stay
available. No settled history is recomputed from a current rate card.

## Explicit non-goals

- No automatic positive admission, provider self-approval, provider-authored
  identity/price, or default-rate fallback for new BYOM routes.
- No payout, financial withdrawal, reward activation, epoch/payment implementation, or
  claim that request settlement is money transfer.
- No arbitrary/non-primary preparation support, new runtime, throughput engine,
  compute-integrity tier, privacy claim, or Trusted Pool behavior.
- No production enforcement, release publication, deployment, merge, hardware
  procurement, spending, operator-secret change, or production qualification.
- No inspection of `d-inference` source and no secrets in worktrees/artifacts.

## Stop and reopen conditions

Implementation starts only after this paired gate and the separate R4 gate pass
and Phase 0 completes. Stop and reopen for any material change to positive-state
origin, dual control, price-contract fields/formula, receipt/activity schema,
release/provider lock order, transaction commit point, R4 architecture,
supported artifact/runtime scope, base revision, slice-5 semantics, or test
strategy. Build 1 may become implementation-complete and locally verified while
physical, release, deployed-service, or production qualification remains
blocked; those states are always reported separately.
