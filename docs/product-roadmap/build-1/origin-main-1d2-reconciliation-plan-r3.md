# Build 1 reconciliation PRD and implementation plan — origin/main 1d2 r3

Status: **PROPOSED; not implementation authorization**. No source or test
implementation may begin under this revision until an independent GPT-5.6 Sol
review of this exact document and
`test-spec-origin-main-1d2-reconciliation-r3.md` reports zero Critical, High,
and Medium findings.

Date: 2026-09-11

Scope: Product Build 1 — Self-Service Model Supply

Repository/base: `origin/main`
`1d2c930bad81704dd0acc0322226725d8b64aceb`.

Frozen dirty Build 1 source worktree:
`/Users/augstar/.codex/worktrees/macprovider/product-build-1`, branch
`codex/product-build-1`, HEAD
`914f7cafcdbcfc1805a10f4f34167218341d5587`. It is historical recovery input,
not the integration base and must not be rebased in place.

Frozen planning inputs:

| Input | SHA-256 | Disposition |
|---|---|---|
| `origin-main-1d2-reconciliation-plan-r2.md` | `10ee7b35492e013e3394fd5e8ec148dfc290f9a5d9f0ee2368516d0fdb402cdb` | Superseded. |
| `test-spec-origin-main-1d2-reconciliation-r2.md` | `55e2f1de30e47f8bcb357fa0a6788b0cd5f3ff0ca3f7adab28b2427aa1a9abd1` | Superseded. |
| `reviews/origin-main-1d2-reconciliation-plan-r2-sol.md` | `3c8ccdf0d6bbb14b7ee0487c449f3b84341b4b32bfacd9d01e12bd9d1f1291cd` | Failed: 0 Critical / 5 High / 4 Medium. |

The historical roadmap at
`/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md` and
baseline `422fc2f13fc62c1ff8987522f822d9ef856e4a96` are context only. No
`d-inference` source was inspected.

## Product outcome and truthful journeys

Build 1 lets a provider discover one supported primary MLX model from a
verified release-bound source, see its authenticated positive size, prepare it
without replacing the incumbent, adopt it explicitly, obtain coordinator and
two-operator admission for the exact catalog identity, serve a request under an
immutable exact-key price contract, and read the request's receipt-bound credit
state. Preparation, provider assertions, signed offers, and probes never mint
positive economic authority. Request settlement is distinct from reward
activation, weekly batching, payout, withdrawal, and money transfer.

The supported journey is:

1. A verified live feed, or safe release-compatible baked fallback, supplies an
   exact candidate, signer, release, freshness, artifact identity, economics,
   and authenticated integer `size_bytes > 0`. Missing or invalid size is
   browse-only.
2. Confirmation repeats the exact size. Preparation reserves capacity,
   downloads to owned staging, enforces the exact stream ceiling, verifies all
   bytes, and atomically publishes a prepared inactive artifact. It does not
   alter the active model or admission.
3. Before publication, cancellation removes only owned staging and preserves
   the incumbent. After publication it returns `too_late` and reconciles the
   prepared inactive artifact. Restart follows journal and filesystem truth.
4. Adoption revalidates prepared bytes and uses the existing drain/swap/
   rollback lifecycle. It performs no hidden network download.
5. A signed offer and bounded probe may reach only
   `network_admitted_unsettled`. An authenticated readiness read shows the exact
   candidate and sanitized approval state.
6. Positive transitions use a structurally closed transition package. A first
   named operator may request settlement capability; a distinct named operator
   consumes the unexpired pending decision atomically with one event after
   fresh re-evaluation.
7. Before dispatch, billing loads one immutable persisted configuration row,
   verifies it, performs an exact `catalog_model_key` lookup, and atomically
   persists the route plus its price contract and `route_reserved` lifecycle
   event. No caller supplies live rates, share, multiplier, formula, or cap.
8. Route authorization and provider acceptance are separate durable facts. A
   route that fails postcheck or never receives the provider's authenticated
   acceptance is never shown as `receipt_pending`.
9. Receipt verification and credit reconciliation join the exact route,
   dispatch, verdict, price contract, scope hash, and ledger generation. The
   provider sees a closed truthful state with authoritative age/freshness; an
   inconsistent join fails the entry closed.

Physical acceptance additionally requires real executable app/CLI actions,
two operator actions, actual MLX inference on a physical Apple Silicon Mac,
immutable receipt persistence, one verified receipt-bound credit
reconciliation, and provider-visible readback. Fixtures cannot qualify it.

## Current implementation classification at 1d2c930

| Roadmap outcome | State | Evidence | R3 disposition |
|---|---|---|---|
| Signed feed production/distribution | Landed | `internal/buyer/catalog_artifacts_feed.go`, `autotune_feeds.go`, release scripts | Preserve; rerun producer/server/release negatives. |
| Verified provider feed consumption | Missing on main; dirty unaccepted implementation | Swift `AutotuneArtifactFeed`, `AutotuneRecommend`, `BYOMDiscovery` | Replay only after gates; invalid live responses never select fallback. |
| Durable preparation/adoption | Missing on main; dirty implementation depends on rejected R4 | Swift durable store and transaction files | R4 must pass its own plan and full-diff audit gates first. |
| Coordinator identity/admission matching | Substantially landed | `artifactidentity.Index`, release snapshot, operator decision, route guard | Preserve as network identity authority. |
| Store-enforced positive origin | Partial | `ws.ModelAdmissionStore` exports generic decision methods; concrete stores expose them | Move persistence and transition machine to an exact closed package boundary. |
| Exact catalog-key pricing | Missing on money path | route carries catalog key; `buyer/billing_recorder.go` still supplies live config and `RateFor(row.Model)` | Billing store alone constructs one persisted immutable price contract. |
| Route versus accepted dispatch truth | Missing | route insertion may survive failed postcheck/crash; no durable provider-acceptance fact | Add append-only dispatch lifecycle and a bound acceptance frame. |
| Provider readiness/activity | Missing | v1 status is event-only; no exhaustive provider settlement read | Add readiness v2 and activity v1 with deterministic pending selection, join oracle, age, and opaque cursors. |
| Executable provider UX | Partial on main; dirty implementation unaccepted | model catalog CLI/app code | Compose only authoritative sources and closed unknown/error states. |
| Physical prepare-to-settle | Blocked/unproven | no fresh signed-feed → physical MLX → settled receipt artifact | Remains a qualification blocker. |

## R2 finding resolutions

| Finding | R3 correction | Proof |
|---|---|---|
| H1 transition boundary | Exact `internal/modeladmission` package, constructor graph, narrow interfaces, and one-shot auth grants; no exported raw positive mutation. | Contracts 3–6; Phase 4; T09–T10. |
| H2 mixed pricing snapshot | One billing transaction selects and verifies a persisted v2 canonical config and creates the route/contract. No economics are accepted from caller memory. | Contracts 7–10; Phase 5; T12–T14. |
| H3 route/dispatch ambiguity | Append-only lifecycle plus authenticated provider acceptance; only accepted routes can be receipt pending. | Contracts 11–13; Phase 5; T12–T13/T16/T21. |
| H4 activity join ambiguity | Exact keys, uniqueness, latest-reconciliation rule, exhaustive precedence table, and `inconsistent_unavailable`. | Contracts 16–18; T16. |
| H5 cursor privacy | AES-GCM opaque scope-bound cursor, exact query grammar, fixed snapshot, rotation/expiry, indistinguishable invalid response. | Contract 19; T16. |
| M1 pending history | Single snapshot and deterministic current-head/recent-terminal selection with explicit timestamps and retention. | Contract 15; T15. |
| M2 open-state freshness | Authoritative started/transition/observed timestamps, persisted thresholds, and separate cached last-known rendering. | Contracts 18 and 20; T16–T17. |
| M3 incomplete Slice 5 snapshot | Exact 40-path cumulative manifest and mandatory resnapshot stop points. | Slice 5 section; T01/T20. |
| M4 auth backend ambiguity | New-endpoint error matrix distinguishes invalid tokens from validator timeout/backend failure while v1 stays byte-compatible. | Contract 21; T15–T16. |

Earlier R1 closures remain mandatory: exact-key price authority, closed positive
origin, provider-visible settlement truth, exact twelve-path R4 prerequisite,
authenticated positive size, exact replay versus fresh re-evaluation, and
continuous origin/Slice 5 checkpoints.

## Normative contracts

The implementation starts from SPEC-010 v1.8 and SPEC-047 v0.1.5 at 1d2 and is
also governed by SPEC-023, SPEC-044, SPEC-022, SPEC-005, SPEC-011, SPEC-001,
and BUILD_SPEC_953. Any new transition, dispatch, price, readiness, or activity
wire/storage contract requires a reviewed forward SPEC version based on the
then-current landed indexes. Version numbers are chosen only after Slice 5 is
resolved.

### Authority and structural transition boundary

1. Local preparation, adoption, benchmark output, signed offer, provider
   assertion, and probe success cannot create `catalog_priced` or
   `settlement_capable`, trusted identity, or price authority. Automatic probes
   stop at `network_admitted_unsettled`.
2. Exact release/member matching resolves `catalog_model_key`; provider/request
   model aliases, artifact labels, hashes, and defaults cannot replace it.
3. Create package `phase4-coordinator/internal/modeladmission`. It owns
   `Event`, `PendingDecision`, transition enums, SQLite migrations, concrete
   memory/SQLite persistence, replay indexes, the state machine, and every raw
   event/pending transaction. Files are `types.go`, `commands.go`, `service.go`,
   `store_memory.go`, `store_sqlite.go`, and `migrate.go`. Raw append/select
   helpers and concrete store fields are unexported. There is no exported
   method accepting an `Event`, arbitrary next-state string, arbitrary actor,
   or SQL executor.
4. `modeladmission.NewSQLiteService(*sql.DB, Dependencies)` and
   `modeladmission.NewMemoryServiceForTest(Dependencies)` return `*Service`.
   `Service` exposes only the closed methods `SubmitOffer(OfferCommand)`,
   `Withdraw(WithdrawalCommand)`, `RecordProbeResult(ProbeCommand)`,
   `RecordLifecycleLoss(LifecycleLossCommand)`, `RequestOperatorTransition(
   *auth.ModelAdmissionGrant, OperatorDecisionCommand)`,
   `ApproveSettlement(*auth.ModelAdmissionGrant, ApprovalCommand)`, and bounded
   read methods. Each command type has unexported target/actor fields and is
   constructed by a named package constructor that validates its closed reason
   and target. Probe constructors can target only unsettled; lifecycle
   constructors can target only withdrawn/revoked/unsettled negative edges.
5. `cmd/coordinator` constructs one `auth.ModelAdmissionGrantAuthority`. It
   passes its issuing interface to `ws.Server` and its consuming/verifying
   interface directly into `modeladmission.New*Service`; WS never receives the
   verifier. `AuthorizeModelAdmission(requestPurpose, requestDigest)` returns
   an opaque pointer `*auth.ModelAdmissionGrant` with unexported fields and a
   random registered handle bound to normalized actor, one of `decision` or
   `approval`, request digest, issue time, and expiry. The transition service
   consumes the handle exactly once while checking purpose and digest. Nil,
   zero, forged, expired, wrong-purpose, wrong-digest, and copied/replayed
   pointers fail before store mutation. Syntactically invalid commands are
   rejected before grant consumption. For a syntactically valid command, grant
   consumption linearizes before authority evaluation and store mutation; every
   success or authority/state failure consumes that handle. An HTTP retry is
   reauthenticated and gets a new handle, while the existing command request
   ID/digest store index provides idempotent response replay.
6. `ws.Server` receives four explicit interfaces: provider commands, lifecycle
   commands, reads, and operator commands. `buyer`, `billing`, `pool`, app, and
   CLI receive no mutation interface. The `ws` package can construct no store
   and cannot invoke raw positive insertion. Existing rows remain byte-valid;
   migration moves ownership, not historical bytes. Memory and SQLite have the
   same atomic pending/event semantics. A distinct approval performs fresh
   head/session/release/member/key/rate evaluation, event append, and pending
   consumption in one critical section/SQLite transaction.

### One immutable price source and route creation

7. Add append-only `billing_config_snapshots_v2`. Each row stores `schema`,
   effective/created timestamps, exact canonical JSON bytes, and SHA-256. The
   canonical object contains exactly: provider share bps, global multiplier
   ppm, the complete exact-key rate-card object, quarantine flags/hold seconds,
   `byom_formula_version`, `max_billable_tokens`, and
   `activity_freshness_policy` with dispatch, receipt, and reconciliation stale
   thresholds.
   Reload/startup creates this single row atomically from one validated config
   value before publishing the corresponding in-memory config. Legacy snapshot
   rows remain untouched. Missing columns or un-reproducible historical hashes
   are never treated as v2 authority.
8. Billing exposes
   `ReserveBYOMRoute(ctx, BYOMRouteIdentity) (ReservedBYOMRoute, error)`.
   `BYOMRouteIdentity` contains route/admission identity and request timing but
   no rate, share, multiplier, formula, cap, config ID/hash, or contract digest.
   In one SQLite transaction the method selects the one v2 row effective at
   `request_start`, strict-decodes it with duplicate/unknown/type rejection,
   recomputes its hash, performs byte-for-byte lookup of the accepted
   `catalog_model_key`, validates non-negative safe-integer rates and caps,
   constructs canonical `byom_price_contract.v1`, inserts the immutable route
   and direct join columns, and appends dispatch event `route_reserved`.
9. The contract contains exactly `schema`, `catalog_model_key`,
   `billing_config_snapshot_v2_id`, `billing_config_snapshot_v2_sha256`,
   `formula_version`, `credit_unit=credits_per_million_tokens`, prompt,
   prompt-cache-hit, and completion rates, multiplier ppm, provider share bps,
   `max_billable_tokens`, dispatch stale seconds, receipt stale seconds, and
   reconciliation stale seconds. Its canonical digest is bound into the route digest. Ledger and
   reconciliation rows repeat route ID/digest and price-contract digest as
   direct columns.
10. New candidate-bound BYOM hot path, receipt synchronization, recovery,
    reconciliation, and replay accept only route ID/digest plus measured usage.
    They reload the immutable route/contract and never call `RateFor`, a current
    feed, current release, current keyring, current session, or live config.
    Missing/corrupt/mismatched snapshot, key, field, row, or digest fails before
    dispatch or closes settlement to quarantine/inconsistent without economic
    activation. Existing non-BYOM and historical paths retain current `RateFor`
    behavior and byte-identical route/receipt/ledger digests.

### Dispatch lifecycle and recovery

11. Add append-only `settlement_route_dispatch_events` keyed by
    `(route_id, sequence)` and unique `(route_id, event_key)`. Each event binds
    route ID/digest, provider/session/generation, timestamp, prior-state digest,
    event type, and closed reason. Legal order is:
    `route_reserved` → `postcheck_authorized` → `dispatch_write_started` →
    `dispatch_write_completed` → `provider_accepted`, with terminal alternatives
    `pre_dispatch_aborted`, `dispatch_failed_before_write`,
    `dispatch_outcome_unknown`, or `provider_rejected`. Events are compare-and-
    append; illegal transitions, duplicates with different bytes, and tuple
    drift fail closed.
12. Candidate-bound BYOM dispatch adds a versioned authenticated provider
    `request_accepted.v1` frame before inference/output. It binds request ID,
    attempt, provider ID, session/generation, route digest, candidate ID, exact
    catalog key, and provider signature under a distinct domain. Only a valid
    frame on the selected live connection appends `provider_accepted`.
    A mutually exclusive signed `request_rejected.v1` frame binds the same
    tuple plus a closed reason and appends `provider_rejected`; it proves no
    inference acceptance and is terminal/no-charge.
    Compatibility negotiation makes new BYOM paid routing unavailable to a
    provider lacking this capability; legacy/non-BYOM dispatch is unchanged.
13. Postcheck failure before write appends `pre_dispatch_aborted`; serialization
    or socket failure before first write appends `dispatch_failed_before_write`.
    A live `route_reserved`/`postcheck_authorized` row is `dispatch_pending`;
    restart recovery closes a pre-write orphan as `pre_dispatch_aborted` with
    reason `coordinator_restart_before_dispatch` rather than leaving it open.
    Crash/failure after write starts but before a durable valid acceptance
    appends or recovers as `dispatch_outcome_unknown`; it is never resent
    automatically, charged, credited, or shown as receipt pending. Recovery
    replays only idempotent lifecycle appends, never the request. Only
    `provider_accepted` may enter receipt-verification waiting.

### Readiness selection

14. `GET /v1/provider/model-admission/status` and
    `model_admission_status.v1` remain byte/schema/error compatible. New
    `GET /v1/provider/model-admission/readiness?candidate_id=<id>` returns closed
    `model_admission_readiness.v2` with exactly `schema`, `generated_at`,
    `cli_version`, `provider_id`, `candidate_id`, `served_model_ref`,
    `catalog_model_key`, `admission_state`, `admission_state_source`,
    `coordinator_event_id`, `state_observed_at`, `approval_state`,
    `approval_expires_at`, `provider_guidance`, and `warnings`. Nulls are
    explicit; unknown/duplicate client fields are rejected; actor, pending ID,
    request digest, reason, credential, and other candidates are absent.
15. One memory lock/SQLite read transaction reads current head plus pending
    history. An active record must match provider, candidate, immutable tuple,
    and current evaluated head, and be unconsumed, uninvalidated, and unexpired.
    The schema adds nullable `expired_at`, `invalidated_at`, and
    `invalidated_by_event_id`, and preserves the existing invalidated flag and
    `consumed_at`. Active means invalidated is false, all three terminal
    timestamps are null, and `now < expires_at`; effective expiry
    begins at `now >= expires_at` even before `expired_at` is materialized. In
    the same transaction/critical section, pending creation first sets
    `expired_at=expires_at` on any elapsed open record, then inserts. A partial
    unique index over rows with invalidated false and all three terminal
    timestamps null permits at
    most one open record per provider/candidate/evaluated head without using a
    wall-clock expression in the index. Selection precedence is: invariant
    violation → `unknown`; greatest active by `(created_at,id)` →
    `awaiting_second_operator`; otherwise current-head unconsumed expiry within
    24 hours of `expires_at`, selecting greatest `(created_at,id)` →
    `operator_review_expired`; otherwise the greatest `(invalidated_at,id)`
    record invalidated by the current head within 24 hours of `invalidated_at`
    → `operator_review_invalidated`; otherwise `not_pending`. Consumed records
    are represented by the resulting head and never as pending. A later active
    record outranks historical terminal records. Head change unrelated to a
    recorded invalidation and terminal facts older than 24 hours yield
    `not_pending`. A relevant historical invalidated row lacking its new
    timestamp/linkage projects `unknown`, never a fabricated terminal time.
    Ties use increasing durable ID after timestamp. Memory and
    SQLite must return identical results across restart and clock boundaries.

### Settlement activity join and exhaustive state oracle

16. New BYOM rows add immutable direct columns: route public activity ID (random
    128-bit value), account-scope hash, candidate ID, catalog key, route digest,
    config-v2 ID/hash, and price-contract digest. Dispatch rows reference the
    route primary key/digest. Verdict rows already join on account-scope hash,
    request, attempt, provider, and route digest. Ledger rows gain the same scope
    hash, route ID/digest, candidate, catalog key, and contract digest.
    Append-only `byom_receipt_credit_reconciliations` binds one route, verdict,
    ledger row, contract digest, reconciliation generation, state
    (`credit_verified`, `zero_verified`, `quarantined`, `reversed`), amount, and
    timestamp. `(route_id,generation)` is unique; generation zero is exactly one
    of `credit_verified`, `zero_verified`, or `quarantined`; the only later
    legal transition is `credit_verified` generation zero to `reversed`
    generation one. The greatest valid generation wins. Gaps, duplicates, or
    any other transition are inconsistent.
17. The activity query first validates uniqueness and exact equality of
    provider, account-scope hash, request ID, attempt, route ID/digest,
    candidate, catalog key, contract digest, verdict route digest, and latest
    reconciliation references. Any duplicate, missing required row for a
    claimed terminal state, bad digest, negative/overflow amount, nonmonotonic
    generation, or cross-reference disagreement yields
    `inconsistent_unavailable` with null receipt result and credits. It never
    falls through to a more favorable state.
18. `GET /v1/provider/model-supply/activity` returns
    `provider_model_supply_activity.v1` with exactly `schema`, `generated_at`,
    `source_observed_at`, `provider_id`, `entries`, `next_cursor`, and
    `warnings`. Every entry has exactly `activity_id`, `request_id`, `attempt_n`,
    `candidate_id`, `catalog_model_key`, `byom_price_contract_digest`,
    `settlement_state`, `receipt_result`, `reason_code`, `provider_credits`,
    `credit_unit`, `terminal_state`, `activity_started_at`,
    `last_transition_at`, `state_age_seconds`, and `freshness_state`.
    `credit_unit` is exactly `credits`. Wire `settlement_state` is exactly one
    of `dispatch_pending`, `pre_dispatch_aborted`, `provider_rejected`,
    `dispatch_outcome_unknown`, `receipt_pending`, `reconciliation_pending`,
    `settled_verified`, `zero_settled`, `quarantined`, `reversed`, or
    `inconsistent_unavailable`. `receipt_result` is null or `valid`, `invalid`,
    `inconclusive`, `missing`. `terminal_state` is null or exactly
    `normal_done`, `provider_error`, `buyer_cancel`, `gateway_timeout`, or
    `upstream_transport_disconnect`. `provider_credits` is null for open/unknown
    states and a non-negative integer only for settled/zero/quarantined/reversed
    terminal states. Precedence is exhaustive:

| First matching authoritative tuple | Wire state | Reason | Receipt | Credits |
|---|---|---|---|---|
| Any uniqueness/equality/digest/generation violation | `inconsistent_unavailable` | `evidence_inconsistent` | null | null |
| Latest reconciliation is `reversed` | `reversed` | `credit_reversed` | `valid` | 0 |
| Latest reconciliation is `quarantined` with matching closed verdict | `quarantined` | `receipt_quarantined` | stored closed result | 0 |
| Closed invalid/quarantined verdict and no contradictory reconciliation | `quarantined` | `receipt_invalid` | `invalid` | 0 |
| Closed inconclusive/quarantined verdict and no contradictory reconciliation | `quarantined` | `receipt_inconclusive` | `inconclusive` | 0 |
| Route reserved/postcheck-authorized and no write/terminal event | `dispatch_pending` | `dispatch_not_started` | null | null |
| Dispatch terminal is postcheck abort | `pre_dispatch_aborted` | `postcheck_failed` | null | 0 |
| Dispatch terminal is restart recovery before first write | `pre_dispatch_aborted` | `dispatch_aborted_before_write` | null | 0 |
| Dispatch terminal is signed provider reject before inference | `provider_rejected` | `provider_rejected` | null | 0 |
| Dispatch terminal is failure before first write | `pre_dispatch_aborted` | `dispatch_failed_before_write` | null | 0 |
| Dispatch is write-started/completed/unknown without accepted event | `dispatch_outcome_unknown` | `dispatch_acceptance_unknown` | null | null |
| Accepted and no verdict | `receipt_pending` | `receipt_missing` | `missing` | null |
| Accepted and open verdict exists | `receipt_pending` | `receipt_pending` | stored `valid`, `invalid`, or `inconclusive` | null |
| Closed verified valid verdict and no final reconciliation | `reconciliation_pending` | `receipt_verified_reconciliation_pending` | `valid` | null |
| Latest reconciliation `zero_verified` with closed matching verdict | `zero_settled` | `receipt_verified_zero` | stored closed result | 0 |
| Latest reconciliation `credit_verified`, closed valid/verified verdict, exact matching ledger, amount equal | `settled_verified` | `receipt_verified_credit` | `valid` | exact amount |
| Every other well-formed closed combination | `inconsistent_unavailable` | `evidence_inconsistent` | null | null |

The weekly ledger `settled`/`settlement_id` values never affect this table and
are never exposed. `reason_code` is exactly one of `dispatch_not_started`,
`postcheck_failed`, `dispatch_aborted_before_write`,
`provider_rejected`, `dispatch_failed_before_write`,
`dispatch_acceptance_unknown`, `receipt_missing`, `receipt_pending`,
`receipt_invalid`, `receipt_inconclusive`,
`receipt_verified_reconciliation_pending`, `receipt_verified_credit`,
`receipt_verified_zero`, `receipt_quarantined`, `credit_reversed`, or
`evidence_inconsistent`, selected from the same first-matching table row; no
free-text reason crosses the endpoint. New routes start activity at
`route_reserved` but cannot say receipt pending until accepted.

### Opaque pagination, freshness, and authentication

19. Activity first-page query grammar is exactly optional `candidate_id` plus
    optional `limit=1..100`; continuation is exactly `cursor` plus optional
    `limit`, with no candidate or raw ID parameters. The cursor is base64url of
    AES-256-GCM `key_generation || nonce || ciphertext`; plaintext is strict JCS
    containing schema/version, provider ID, nullable candidate, frozen internal
    maximum route ID, last-seen route ID, issued/expiry timestamps, and page
    schema. A process-local random current key and one previous generation are
    held only in memory; rotation retains the previous key through the maximum
    15-minute cursor TTL. Restart invalidates old cursors safely. Tamper,
    truncation, expiry, unknown generation, wrong provider/candidate/schema, or
    arbitrary bytes all return the same `400 invalid_cursor` body and log no
    decoded scope. Stable descending predicates are `id <= frozen_max AND id <
    last_seen`, after provider/candidate filtering. New inserts cannot create
    gaps/duplicates. The response exposes only random `activity_id`,
    `next_cursor`, and timestamps, never internal global row IDs or cursor
    plaintext.
20. `activity_started_at` is the immutable route creation time;
    `last_transition_at` is the maximum timestamp of the authoritative dispatch,
    verdict update, or winning reconciliation that selected the state;
    `state_age_seconds` is floor(max(0, database snapshot time minus
    `last_transition_at`)). Every entry includes those fields and
    `freshness_state` exactly
    `fresh`, `stale_open`, or `terminal`. `source_observed_at` is the database
    snapshot time, not a synthetic event time. Dispatch pending uses its
    immutable contract's dispatch threshold; open receipt uses the receipt
    threshold; reconciliation pending uses the reconciliation threshold.
    Terminal rows stay `terminal`. The app
    stores the response's real `source_observed_at` and separately labels a
    failed refresh as `last_known` with `last_successful_fetch_at`; it never
    substitutes the current clock for source freshness or calls stale state
    current earning/idleness.
21. New readiness/activity endpoints use an endpoint-specific provider read
    authenticator. Exact matrix: provider tokens disabled → 503
    `provider_tokens_not_enabled`; validator missing → 503
    `provider_tokens_unavailable`; read-only capability missing → 503
    `provider_tokens_read_only_unavailable`; missing bearer → 401
    `unauthorized`; invalid/revoked/expired bearer → 401
    `invalid_provider_token`; validation deadline → 503
    `provider_token_validation_timeout`; validator/backend error → 503
    `provider_token_validation_unavailable`; admission store failure → 503
    `model_admission_store_unavailable`; billing store failure → 503
    `model_supply_activity_unavailable`. Bodies reveal no backend detail. The
    existing v1 helper and response remain byte-for-byte unchanged, including
    its current 401 behavior on validator error.

### Provider artifact, replay, and UI boundaries

22. Actionable preparation requires signed-feed integer `size_bytes > 0` for
    live and baked sources. Missing, zero, negative, non-integer, unsafe, or
    mismatched sizes create no transaction, staging, reservation, config,
    journal, or offer mutation. Early EOF and the first byte over declared size
    fail regardless of content length/chunking.
23. Transport replay resends byte-identical signed bytes under the original
    request identity and returns the stored result without another probe/event.
    Explicit fresh re-evaluation creates new request ID, timestamp, nonce,
    idempotency key, digest, and signature while preserving the protected offer
    tuple and rechecking current authority.
24. GGUF retry proof stays private/local and never becomes price/admission
    authority. Primary MLX is the only new preparation scope.
25. UI projection never outranks durable artifact/journal state, admission
    head/pending state, route/dispatch lifecycle, immutable price contract,
    receipt verdict, or reconciliation. Catalog economics, readiness, request
    settlement, rewards, payout, and payment are separate states.

## Ownership and dependency graph

| Owner | Boundary |
|---|---|
| Release publisher | Current/compatible catalog and artifact identity sets under one generation. |
| `internal/auth` grant authority | Named operator authentication and one-shot purpose/digest-bound grants; no admission storage. |
| `internal/modeladmission.Service` | Sole transition machine and raw event/pending persistence owner. |
| Pool/provider section | Live provider/session/generation/receipt key binding. |
| Buyer route guard | Live pre-dispatch admission expectation and postcheck; no economics. |
| Billing store | v2 config snapshots, exact-key price contract, immutable route, dispatch events, verdict/ledger reconciliation, activity read. |
| Swift artifact transaction | Owned staging, prepared/active lifecycle, cancellation/recovery; no network/economic authority. |
| CLI/app | Capability negotiation and rendering only. |

Dependency flow:

`release identity → signed offer → unsettled probe → authenticated grant →
closed transition → exact catalog key → billing v2 snapshot → route+price
reservation → postcheck → dispatch → provider acceptance → receipt verdict →
receipt-credit reconciliation → scoped provider activity`.

## Migration, compatibility, rollback, and lock graph

- Freeze the dirty Build 1 worktree with a private ref, verified bundle,
  tracked patch, untracked and SHA manifests, and 0700/0600 recovery storage.
  Exclude builds, caches, secrets, and operator roots. Restore
  `Package.resolved` provenance before a landing commit.
- Do not rebase the dirty worktree. Create a fresh hidden worktree from the
  current approved dependency base. Replay only approved slices with exact
  per-slice manifests.
- Package migration preserves event/pending rows and wire bytes. New pending
  timestamp columns are nullable for historical rows; historical ambiguity
  projects `unknown`, never pending.
- New config-v2, dispatch, direct join, activity ID, and reconciliation data are
  forward-only. Existing route JSON/digests and ledger rows are not updated or
  backfilled. Candidate-bound routing is enabled only when all new stores and
  provider acceptance capability are ready.
- Preserve provider-section → registry → release-read lock order. Operator auth
  and grant issue precede admission locks. Model-admission memory mutation uses
  one mutex; SQLite approval uses one transaction. Route/price reservation
  holds neither provider nor release locks. Dispatch events use billing DB
  transactions and do not call back under DB locks. Activity is a bounded read
  transaction and touches no live release/config/keyring source.
- Rollback first disables new BYOM routing and new read capabilities, retaining
  immutable rows. Old clients stay on status v1/unknown. Historical and
  non-BYOM pricing continue. No settled history is recomputed.

## Exact active Slice 5 snapshot and disposition

Observed at `2026-09-11T01:15:12.207214Z` in
`/Users/augstar/macprovider-byom-v02-slice5`. Branch
`feat/byom-v02-slice5-intake-pipeline`, HEAD
`72eeaec7cf80e3f8c1f71d1754c57c87417038e8`, merge base
`1d2c930bad81704dd0acc0322226725d8b64aceb`: five commits, 18 modified tracked
paths, 13 untracked paths, 40 cumulative committed/dirty paths. Canonical
newline-terminated `SHA256(bytes)  path` manifest digest:
`f6cddfeb50603df2f0db00e2210ce3d0098a03e060284f39a98c725c80683527`.

| State | Path | SHA-256 |
|---|---|---|
| committed | `audits/2026-09-11-byom-v02-slice5/AUDIT_BYOM_V02_SLICE5_SPEC_PROMPT.md` | `263716548049ac20f0f13b95e2cd31b3e36f6212a93d612ed5959ce78ce21c73` |
| committed | `audits/2026-09-11-byom-v02-slice5/AUDIT_BYOM_V02_SLICE5_SPEC_R1.md` | `923700c3404d1eb744a25fd67cf62e3e3e471fc62147b5d689609f66991130ed` |
| committed | `audits/2026-09-11-byom-v02-slice5/AUDIT_BYOM_V02_SLICE5_SPEC_R2.md` | `832f672ae0f1e0834c8b6c4715202d9ca29f5f8b0f71f1118490d0fdf3fd4a64` |
| committed | `audits/2026-09-11-byom-v02-slice5/AUDIT_BYOM_V02_SLICE5_SPEC_R3.md` | `18dc510fb6ff8cb54af4648107b0fe2c1a6ae63df28471523e9d60c41c52050d` |
| untracked | `docs/runbooks/catalog-monthly-intake-release.md` | `4a3c43998ea5a6efda32d707a49e1cc5bcb76a3323332e0f94ddd4e7c9ac2e5c` |
| dirty | `phase4-coordinator/cmd/coordinator/main.go` | `2bd58fb26dfe4b1f9d6ceb277509e03f7681e7fa4d01a9666c45df7b7cfd4183` |
| untracked | `phase4-coordinator/internal/buyer/intake_hook.go` | `88561b9c261f0c040dfa5d78975158a90791ad24ed16453fd5b0df0c2dc85c9f` |
| untracked | `phase4-coordinator/internal/buyer/intake_hook_test.go` | `c84b9a246de08f36ea204958636a22083b60d2847dc9de7f123fe9c54c67d9b5` |
| dirty | `phase4-coordinator/internal/buyer/server.go` | `ee541b1398acbe05ab8bc5492357f781a9b4926facf3b2c307ac555b85928c33` |
| dirty | `phase4-coordinator/internal/config/config.go` | `df480a7f1ac0f197881a0d1ffa5b0a6eef099e1ec0eb6cda91a88ddfa7b15090` |
| untracked | `phase4-coordinator/internal/intake/aggregator.go` | `c2fd4f8c75aceb4b35f86f825caba8be913fee88715415cd7a6d6d987e1c984f` |
| untracked | `phase4-coordinator/internal/intake/aggregator_test.go` | `a48c4db3c9449ad242c468e9cdbda079e24ef834f9b5900cdaf984eecc52b4be` |
| dirty | `phase4-coordinator/internal/onboarding/store_pg.go` | `6e98dce4b2260651bddb54f18fd5d751263b36d266e91340aa405bb5f26dfacf` |
| dirty | `phase4-coordinator/internal/stats/handlers.go` | `ca5d42fda8752180572a5f31798799f0c33a350493ce12a23dbb8842cf77db5c` |
| dirty | `phase4-coordinator/internal/stats/health_status.go` | `377a5a8354606cc31d7c1596d7c24ca7054605f473d09d8dba2a1fe1090a379a` |
| untracked | `phase4-coordinator/internal/stats/intake_handler.go` | `54e23d68c4c1b6b9b67b9609321502ffa5536b23ad1a24bcca07304880c93e30` |
| untracked | `phase4-coordinator/internal/stats/intake_handler_test.go` | `ad22abfb5fbc3e1c343eb025e02b61eb8340a4176fa516ae78bfbae086b37647` |
| dirty | `phase4-coordinator/internal/stats/integration_test.go` | `f85a31384edfd374a2d6821ecf699a38c23a13081badc6630b00508015f5d70b` |
| untracked | `phase4-coordinator/internal/stats/migrations/028_stats_intake_current.up.sql` | `f38cd661f9375144c100c350a0ff2d94770e5a50624f5a1eb338b3d8a26acda0` |
| dirty | `phase4-coordinator/internal/stats/mux.go` | `4773f71beff5bdce6a35c28aa6a1edadb6866d2f625d15cdf85d5491adbf88b1` |
| dirty | `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot.go` | `755a1ca009bf4e2a2bd9300003bcb295f5c162bb06622984ba2dd651853640e1` |
| dirty | `phase4-coordinator/internal/stats/rollup/config.go` | `125e6a2222db27c304c2ab1c932f9da660e71c0326a74257b70d28ae541f828b` |
| dirty | `phase4-coordinator/internal/stats/rollup/health.go` | `598ea4e39eb20467f15b742b2bba91e6a6be2f36dc61bda6f86fd21cfb3ee4d5` |
| untracked | `phase4-coordinator/internal/stats/rollup/intake.go` | `61bd1b6157b5013d318115fd2082c8233a097a83107664c7746ba08bf3030e63` |
| untracked | `phase4-coordinator/internal/stats/rollup/intake_test.go` | `36e28a41c40e7430f32ca7a1bdcbd0a9b627ef9770b6fac8f128e48419e91ca0` |
| dirty | `phase4-coordinator/internal/stats/rollup/runner.go` | `0e325ee1ca8254fdd5d1c95f2021d6e48d0274fa89486e2f49ad3dc97da41593` |
| dirty | `phase4-coordinator/internal/stats/rollup/snapshot.go` | `0d0d2ab3dd5d8be5cd080b48f5b76b2f463c8c8d6da1abc780b3be5a609d3da4` |
| untracked | `phase4-coordinator/internal/stats/store/intake.go` | `cb2dc03a27cb1b89f0cef27827becfa9e1b7921c7930c6505aaf98801fb0364a` |
| dirty | `phase4-coordinator/internal/ws/admin_hardware_trust_test.go` | `bf7f8d45c7594919ae47503c1e3af49900f34f70f1b3466664302c1c0e2ab1d2` |
| dirty | `phase4-coordinator/internal/ws/model_admission.go` | `bf7b398e1975c116e7c150063591c34004e2ba16c449de55778996fbd7327a84` |
| untracked | `phase4-coordinator/internal/ws/model_admission_intake.go` | `2051ca3393422deb99989bb03ac85f02f36a5b8b342400b10baa38280dc48543` |
| untracked | `phase4-coordinator/internal/ws/model_admission_intake_test.go` | `74c1136092c002af364c248ffa3f5944c8f7ba04cf878e0ad037412091c12e2d` |
| dirty | `phase4-coordinator/internal/ws/model_admission_operator_test.go` | `27c85ed14cfa81d59c45f4139043fdffa17c1688b468bad07cbbe206b9111e96` |
| dirty | `phase4-coordinator/internal/ws/server.go` | `c52059d954e8b41663cb1f6938c937ce948539dc0c9e07759f315d1e1dc211a0` |
| dirty | `scripts/catalog-release.py` | `f4774d3f22db7379f0cc0f39013c8d4145b72201f0eae688c02a336b4a824731` |
| committed | `specs/CONFORMANCE.json` | `5cd5e6787da9f10a21084f5ce808b03d27ad35ff9199c4050e8eefc5ce7b9c68` |
| committed | `specs/README.md` | `c3413de5164797953c453237c6cab37fbcc02209a9d6b2a39c9d421ae27b780a` |
| committed | `specs/SPEC-017-network-stats-api.md` | `9dbc43b48ed78ad805ca2a88f72e62a2227855c5a4b92c361be45a7663fd9d9f` |
| committed | `specs/SPEC-023-installer-autotune-recommend.md` | `ac6212b7b5a2c9cf3683abb060cb1afbb8d8b5a8c842425011689e1cb26af655` |
| committed | `specs/SPEC-047-network-model-admission.md` | `b990728ea52c0432c30d1227b9c8a8947d2907ac9d158299be9064aa8e9584ce` |

Slice 5 is a separate prerequisite for shared files, not landed evidence. Its
direct Build 1 conflicts are `cmd/coordinator/main.go`, `buyer/server.go`,
`ws/model_admission.go`, `ws/model_admission_operator_test.go`, `ws/server.go`,
`scripts/catalog-release.py`, SPEC-023, SPEC-047, CONFORMANCE, and README.
Config, intake/stats, onboarding, the monthly runbook, and their tests are
cumulative dependencies that Build 1 must preserve. SPEC-017 and audit files are
preserved without Build 1 edits.

Before any shared-file implementation, Slice 5 must either land and become the
new base, be explicitly abandoned by its owner, or be committed/reviewed as a
named prerequisite of a documented dependent Build 1 branch. Build 1 never
copies its dirty/untracked files. Independent non-overlapping provider and
billing work may proceed only after the Build 1/R4 gates and recovery checkpoint.

Fetch/prune and regenerate HEAD, merge base, committed/dirty/cumulative path
hash manifests at plan review, recovery completion, fresh worktree creation,
before every shared SPEC/runtime write, before/after each audit fix, before full
audits, and immediately before PR create/update. Movement in this unmerged
external worktree does not change the approved 1d2 base and does not by itself
invalidate this docs-only gate. It updates dependency evidence. Before source
replay, a mismatch is a hard stop only for the affected slice: preserve the
Build 1 branch, regenerate impact analysis, and reopen this gate if Slice 5
lands, if Build 1 would modify a path whose external bytes are still moving, or
if its current contracts change a planned owner, authority, schema, lock, or
test oracle. Non-overlapping approved work may continue with the new snapshot
recorded. Build 1 never freezes or interferes with the other session.

## Corrected R4 prerequisite

The exact rejected-baseline transaction closure remains:

| Path | SHA-256 |
|---|---|
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `5bc526e395b048c9d1c41cede30d7430321da83395d2a9a02590e35ecfa4b4df` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift` | `260ad23c6a845d76c55b63b0098554e61e123bbca284c25dcf3e94298c7529ef` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionReservationMigrationTests.swift` | `a0c700eb26cce0938d6dcf973f2dea1eacd8194de2a368ad1fb2270611aa2c35` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `bf45cf3a914b377d61ecd10b9013467784acf4a9f234fee01e1f5ebd0c7d55cb` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift` | `009611a1f01fb26dc695ae588abb7e401d1b4cf93c90d6e3fa21249bf6144121` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionFixtureWrites.swift` | `356ea2f3d5efc0f3384953cb08c609a8d4934955a2b18bf184bd59f6706faaee` |

The prior R4 implementation had 79 targeted passes but failed independent code,
security, and architecture audits. It is rejected. No dependent preparation
replay occurs until a later R4 plan/test review has zero Critical/High/Medium,
an isolated implementation commit/tree and complete transaction closure are
pinned, all targeted tests pass freshly, and three full-diff audits report zero
Critical/High/Medium. Any R4 ownership, capacity, commit-point, cancellation, or
recovery change reopens this plan.

## Bounded implementation phases

0. Freeze writers, create and verify the private recovery checkpoint, restore
   package-lock provenance, resnapshot origin/Slice 5, and create a fresh hidden
   worktree only after both plan gates pass.
1. Freeze 1d2 golden event/pending/route/status-v1 behavior and add failing
   contract tests. Do not implement through a failing plan gate.
2. Complete the independent R4 correction and audit gate.
3. Replay provider-only feed, exact-size preparation, cancellation, recovery,
   adoption, CLI/app action, and retry slices without positive promotion.
4. Introduce `internal/modeladmission`, auth grants, narrow interfaces, and
   memory/SQLite migration. Convert offer/withdraw/probe/lifecycle/operator
   callers and delete generic positive access.
5. Add config-v2 authority, atomic route/price reservation, dispatch lifecycle,
   provider acceptance, immutable settlement/reconciliation, and legacy
   compatibility.
6. Add readiness selection, exhaustive activity query, opaque pagination,
   freshness, endpoint-specific auth, and independent capability advertisement.
7. Compose truthful CLI/app states, typed recovery, pagination, localization,
   and accessibility. Operator actions remain absent.
8. Reconcile current SPEC governance, run targeted and broad verification, then
   three independent GPT-5.6 Sol full-diff code/security/architecture audits to
   zero Critical/High/Medium. Prepare a reviewable PR; do not merge/deploy.

## Acceptance, observability, hardware, and non-goals

Every roadmap outcome maps to tests T03–T22 in the paired specification.
Observability uses bounded reason codes and durations for feed/size/preparation,
transition/grant, price resolution, route/dispatch, receipt and reconciliation
lag, cursor failure, auth backend failure, and activity age. Logs exclude raw
feeds/envelopes/receipts, prompts/outputs, account scope, local paths/identity,
journals, credentials, keys, actor secrets, payout data, and cursor plaintext.

Physical qualification requires supported Apple Silicon, primary MLX bytes,
sanitized hardware/software context, a valid signed release/feed, independently
justified Tier2/reference data, isolated services/databases, test-scoped buyer,
provider, and two-operator identities, actual inference, receipt, exact price
contract, reconciliation, and provider readback. Missing prerequisites leave
T22 **BLOCKED / UNPROVEN**. Fixture, SwiftPM, deterministic-provider, synthetic
probe, local integration, release, deployment, and production evidence remain
distinct.

Non-goals are automatic/provider positive admission, provider-authored pricing,
default/normalized BYOM rates, payout/withdrawal/payment/epoch implementation,
reward or economic activation, arbitrary/non-primary preparation, new runtime,
throughput work, compute-integrity tier, privacy/Trusted Pool claims, release,
deployment, merge, hardware procurement, spending, operator-secret changes,
production qualification, or inspection of `d-inference` source.

Implementation completion, local verification, hardware qualification, release
qualification, deployment, and production activation are reported separately.
Material changes to the package boundary, grant semantics, price/config fields,
dispatch acceptance, activity oracle/cursor, R4 architecture, base/Slice 5,
hardware scope, or test strategy reopen the adversarial plan gate.
