# Independent adversarial review — Build 1 origin/main 1d2 reconciliation plan r2

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol lane, high reasoning

Verdict: **REJECTED — implementation remains unauthorized**

Severity counts: **0 Critical / 5 High / 4 Medium / 0 Low**

## Exact reviewed inputs

- Repository base: `origin/main` `1d2c930bad81704dd0acc0322226725d8b64aceb`, tree `39270b08dee665a298e3a67580b127d9368e0f65`.
- Frozen dirty Build 1 worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, HEAD `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Plan: `origin-main-1d2-reconciliation-plan-r2.md`, SHA-256 `10ee7b35492e013e3394fd5e8ec148dfc290f9a5d9f0ee2368516d0fdb402cdb`.
- Test specification: `test-spec-origin-main-1d2-reconciliation-r2.md`, SHA-256 `55e2f1de30e47f8bcb357fa0a6788b0cd5f3ff0ca3f7adab28b2427aa1a9abd1`.
- Failed R1 review: `origin-main-1d2-reconciliation-plan-r1-sol.md`, SHA-256 `b88eec568bec45bed08946131f2649fb55d5d2fb32c6dfb98b21fe00eedbe87b`.
- Impact assessment: `origin-main-1d2-impact-sol.md`, SHA-256 `8541a4e495b90d047da1cbe8e049f79a3fcd28810368e6a7f4944739ba75c745`.
- Active slice 5 observed at branch HEAD `034c9d2e258ae182f3dc0d636b9ec177ecf0defa` plus dirty working state. At review time the complete 30-path cumulative manifest from `1d2c930` had SHA-256 `a8cbd8a0b85e0b820dcd0213e38bc31fda2a1606ab4ef6de277e03dc02e8d482`.

The input digests and base objects matched. I inspected the plan and test specification, the landed admission, release, route, auth, billing, receipt, and ledger code independently, the frozen R4 file closure, and the active slice-5 worktree. I did not inspect `d-inference` source and made no source or test edits.

## R1 closure assessment

- R1 M1 is closed: the twelve R4 paths exist and their bytes match the R2 manifest.
- R1 M2 is closed at plan level: actionable preparation now requires authenticated integer `size_bytes > 0`, with early EOF and overflow enforcement.
- R1 M3 is closed at plan level: byte-identical transport replay and explicit fresh re-evaluation are separate operations and have distinct test oracles.
- R1 H1, H2, H3, and M4 are improved but not closed. The remaining gaps below prevent safe implementation of the promised economic authority, store-enforced transition origin, provider-visible settlement truth, and active-work isolation.

## Findings

### H1 — The promised store-enforced positive-transition boundary has no implementable Go package or constructor boundary

**Evidence**

- Plan clauses 3–4 require the raw memory/SQLite append to be private to a closed transition service and require even a same-package helper to be unable to append a free-form positive state (`origin-main-1d2-reconciliation-plan-r2.md:128-140`). Phase 4 says only to “introduce the closed transition service” and “make raw positive append private” (`:437-443`); it does not name the package split, constructors, interfaces, or dependency direction that make this true.
- T09 demands that WS, buyer, billing, app, and a same-package helper cannot call such an API (`test-spec-origin-main-1d2-reconciliation-r2.md:139-157`). In Go, unexporting a method within package `ws` does not prevent another `ws` file from calling it; an AST name scan is not an authority boundary.
- The landed surface is explicitly broad: `ModelAdmissionStore` exports `AppendModelAdmissionDecision`, `CASAppendModelAdmissionDecision`, and `AppendModelAdmissionApproval` (`phase4-coordinator/internal/ws/model_admission.go:65-82`), the exported `SQLiteModelAdmissionStore` exposes those methods (`:644-649`, `:692-694`), and memory exposes the same operations (`:267-277`). Lifecycle and probe code also call the generic append directly.

**Consequence**

An implementer can satisfy the prose and search tests by renaming or wrapping methods while leaving a constructible concrete store or same-package append path that mints `catalog_priced` or `settlement_capable`. The claimed trust boundary would remain convention-enforced rather than structurally enforced, so provider evidence, a future helper, or active slice work could regain an unauthorized positive path without a compiler failure.

**Required correction**

Specify the exact package/file ownership and constructor graph. The persistence concrete types and raw event/pending transaction must be constructible only inside a package that also owns the closed transition machine; production callers must receive separate narrow offer, withdrawal, lifecycle, read, and authenticated-operator command interfaces whose methods accept closed command types rather than a caller-created `ModelAdmissionEvent` or target string. Define how the WS package obtains a validated opaque operator capability without an import cycle, how zero/copied/expired/wrong-purpose capabilities fail, and how memory/SQLite test stores are instantiated without exporting raw positive mutation. Replace AST-name assertions with external-package compile tests, production dependency/API inventory, and runtime attempts through every returned interface/concrete value.

### H2 — The price contract can still label live rates with a different immutable config snapshot

**Evidence**

- R2 binds `config snapshot id`, `config hash`, the three rates, multiplier, share, formula, and cap (`origin-main-1d2-reconciliation-plan-r2.md:145-153`) but never states that one billing-store operation must derive every config-owned field by reading and verifying the same persisted `ledger_config_snapshots` row.
- The landed path demonstrates the concrete race the plan must close: `billing_recorder.go` supplies `ConfigSnapshotID` independently while obtaining `RateEntry`, multiplier, and share from an in-memory `billingCfg` (`phase4-coordinator/internal/buyer/billing_recorder.go:427-431`). The stored config hash is computed from a canonical structure containing the full rate card, share, multiplier, and settlement flags (`phase4-coordinator/internal/billing/snapshot.go:17-49`).
- T12 says to race config reload and demand a coherent result, and T13 freezes contract bytes, but neither defines the oracle that the exact rate entry, share, multiplier, formula version, and cap provenance must reproduce the persisted snapshot identified by the contract (`test-spec-origin-main-1d2-reconciliation-r2.md:199-240`). A self-consistent contract built from mixed A/B inputs can pass its own digest checks.

**Consequence**

A reload interleaving can produce a validly digested route whose `config_snapshot_id`/hash name configuration A while the billed rate or provider share came from configuration B. Later recovery will faithfully replay the wrong economic decision, and the provider activity endpoint will describe it as verified settlement.

**Required correction**

Make the persisted configuration row the construction authority. Define one billing-store API/transaction that loads the exact snapshot ID, parses the closed rate-card representation, recomputes and verifies its full config hash, performs exact byte-for-byte `catalog_model_key` lookup with no normalization/default fallback, and returns the contract fields. Define the immutable provenance of formula version and `max_billable_tokens` if they are not members of the existing config snapshot. Route construction must reject any separately supplied live rate/share/multiplier. Add barrier tests with snapshots A and B that deliberately swap ID, hash, exact key, rates, share, multiplier, formula, and cap at every reload boundary, plus database corruption/missing-row tests. The independent oracle must rebuild the contract from the stored snapshot row, not from the contract under test.

### H3 — A route that is never dispatched is permanently indistinguishable from a provider request awaiting a receipt

**Evidence**

- The landed compare-and-insert deliberately leaves the immutable route snapshot standing when its postcheck fails, while dispatch and settlement do not occur (`phase4-coordinator/internal/ws/model_admission_operator.go:938-950`, `:977-993`). A process crash after insert and before dispatch has the same durable shape.
- R2 makes the route row itself the activity source and says a route is visible as pending before any verdict (`origin-main-1d2-reconciliation-plan-r2.md:200-205`; T16 at `test-spec-origin-main-1d2-reconciliation-r2.md:294-304`). T13 simultaneously requires a route postcheck failure to be a pre-dispatch no-charge outcome (`:235-241`).
- No contract or phase adds a durable dispatch disposition or defines the crash/postcheck mapping for activity.

**Consequence**

The provider can be shown a “receipt pending” request that was never sent to its Mac, indefinitely. The same ambiguous row can be produced by authorization drift, a coordinator crash, or a dispatch failure. This violates the central truthful request → receipt → credit journey and makes recovery unable to decide whether to resend, close, or display the attempt.

**Required correction**

Add a durable, append-only route dispatch lifecycle tied to the route row and define its linearization points: route reserved, postcheck passed, dispatch attempted, provider accepted (if that acknowledgement exists), pre-dispatch aborted, and outcome unknown after crash. Specify idempotent recovery and which states may become `receipt_pending`; a bare route row or postcheck-aborted row must not. Cover crash/failure at insert, both postchecks, dispatch serialization/write/ack, and recovery. Update T12/T13/T16/T21 so each durable state has a truthful provider projection and no-charge behavior.

### H4 — The settlement activity contract lacks the normative join and state table needed to prove `settled_verified`

**Evidence**

- The response declares fields but does not enumerate `settlement_state`, `receipt_result`, `reason_code`, or `terminal_state`, their nullability, or the exhaustive precedence for combinations (`origin-main-1d2-reconciliation-plan-r2.md:188-216`). “All other combinations” are grouped into several different outcomes without a decision table.
- Existing storage has independently changing sources: route snapshots are immutable, receipt verdicts have closed/result/outcome/reason fields (`phase4-coordinator/internal/billing/store.go:324-366`), and ledger rows have usage, credits, quarantine, settlement, privacy exclusion, and reward exclusion state (`:79-119`). Receipt and ledger rows can be missing, delayed, quarantined, or updated by recovery/reconciliation.
- T16 names several cases but does not define which exact row version wins, the complete join tuple (including account-scope hash), how a ledger row is proven to be the reconciliation of that verdict and price contract, or precedence when valid receipt, quarantine, zero settlement, exclusions, and credit fields disagree (`test-spec-origin-main-1d2-reconciliation-r2.md:279-306`).

**Consequence**

Two reasonable implementations can return different states for the same database. A loose join can combine the right provider/request with the wrong scope, contract, or reconciliation generation and expose credits as `settled_verified`; a conservative implementation can hide a real terminal result. Neither the tests nor a reviewer has an independent oracle for the economic claim.

**Required correction**

Add a normative, exhaustive mapping table from the exact route/dispatch/verdict/ledger tuple to every wire field. Freeze the complete enums and nullability. Define the unique join keys, required account-scope hash equality without exposing scope, direct price-contract key/digest equality, reconciliation/finality marker, row-version precedence, quarantine/reversal precedence, exclusions, zero-credit terminal cases, and corruption/inconsistency behavior. The query must fail the entry closed to `inconsistent_unavailable` when any required equality or uniqueness condition fails. Generate table-driven tests from that mapping and independently seed every valid and invalid tuple.

### H5 — Raw numeric activity cursors cannot simultaneously be “foreign-cursor” rejecting, scope-bound, and non-leaking

**Evidence**

- The endpoint accepts raw `after_id` and `through_id`, uses the SQLite route ID as `activity_id`, and requires later pages to repeat a watermark (`origin-main-1d2-reconciliation-plan-r2.md:188-206`). It does not freeze the exact first/later-page grammar or predicates.
- T16 requires malformed, stale, and foreign cursors to fail while also proving no cross-provider/candidate leakage (`test-spec-origin-main-1d2-reconciliation-r2.md:281-292`). With an integer cursor, deciding that ID N is “foreign” requires looking up N and distinguishing another provider/candidate from an absent/stale/arbitrary bound. That becomes an existence oracle over global route IDs. It also does not bind a later cursor to the original candidate filter or query version.

**Consequence**

The implementation either accepts scope-changing/arbitrary bounds and cannot meet the test claim, or rejects them in a way that reveals activity existence across providers/candidates. Reusing a cursor with another candidate can create gaps, duplicates, or an inconsistent traversal.

**Required correction**

Use an opaque authenticated cursor containing schema/version, provider ID, optional candidate filter, frozen through ID, last-seen ID, and expiry/key ID, or explicitly redefine numeric IDs as non-validating bounds and remove the impossible “foreign” distinction. Freeze first-page and continuation parameter combinations, exact descending predicates, empty/end behavior, filter binding, rotation/expiry semantics, and indistinguishable error responses. Add enumeration, tamper, cross-provider, cross-candidate, key-rotation, concurrent insert, and replay tests.

### M1 — Readiness does not define which retained pending record determines expired or invalidated state

**Evidence**

- R2 requires one snapshot and allows `not_pending`, `awaiting_second_operator`, `operator_review_expired`, `operator_review_invalidated`, or `unknown`, but defines no selection or precedence when a candidate has multiple retained pending records (`origin-main-1d2-reconciliation-plan-r2.md:166-187`).
- The landed stores retain pending records and index them by request or ID; candidate-wide invalidation updates every open record, and no current API returns a deterministic candidate projection (`phase4-coordinator/internal/ws/model_admission_pending.go:77-94`, `:114-119`, and the SQLite pending table/select path).
- T15 tests each state separately but not multiple expired, invalidated, consumed, and current pending records for one candidate (`test-spec-origin-main-1d2-reconciliation-r2.md:259-277`).

**Consequence**

Memory iteration order, SQLite row order, or retention history can change the reported approval state. A historical invalidation can mask a new valid pending decision, or an expired record can remain provider-visible forever after a later event.

**Required correction**

Define a single candidate readiness query and deterministic precedence using evaluated head, creation/id order, consumed/invalidated/expiry status, and retention horizon. State exactly when historical expired/invalidated facts cease to be projected and when `not_pending` applies. Add memory/SQLite parity tests with multiple overlapping histories, restart, concurrent new pending creation, and clock boundaries.

### M2 — Activity has no truthful age/freshness field for an open or last-known state

**Evidence**

- The exact entry field set has receipt and credit timestamps only; both are null for the initial pending route. `generated_at` is the time of the read, not the age of the underlying request (`origin-main-1d2-reconciliation-plan-r2.md:191-205`).
- Phase 6 and observability claim “freshness watermarks” and activity freshness (`:453-458`, `:499-501`), while T16 only freezes an ID high-water mark (`test-spec-origin-main-1d2-reconciliation-r2.md:281-303`).

**Consequence**

A week-old unresolved attempt and a just-dispatched request are indistinguishable as pending. Refreshing the endpoint makes `generated_at` current and can make stale state appear freshly observed, defeating the truthful UX requirement.

**Required correction**

Add authoritative route/dispatch creation and last-transition timestamps plus a closed freshness/age classification or explicitly define the UI age computation and stale threshold from those timestamps. Define cache/503 last-known presentation separately from a fresh database read. Test clock boundaries, old open rows, delayed verdicts, reconciliation lag, restart, and local cached last-known data.

### M3 — The R2 “at this revision” slice-5 inventory omits direct Build 1 conflict paths

**Evidence**

- The plan lists only a subset of dirty slice-5 implementation paths (`origin-main-1d2-reconciliation-plan-r2.md:369-377`).
- At this review, the active worktree's 30-path cumulative manifest includes direct overlaps omitted from that statement, including `phase4-coordinator/cmd/coordinator/main.go`, `internal/ws/model_admission.go`, `internal/ws/server.go`, `internal/ws/model_admission_intake.go`, stats handlers/mux/rollup files, and all three governing SPECs plus governance indexes. The manifest digest is recorded in the reviewed inputs above.
- The later checkpoint rule is good, but the current plan gate is supposed to be grounded in the exact active state before implementation authorization; the omitted WS and SPEC paths directly affect transition ownership and normative versioning.

**Consequence**

The conflict table and implementation sequencing can be approved against a materially incomplete active-work snapshot. If Phase 0 treats the prose list as its expected baseline, it can miss that slice 5 already changes the same admission store/server and SPEC-047 surfaces R2 intends to restructure.

**Required correction**

Replace the prose subset with a durable exact committed/dirty/cumulative path-and-hash manifest, its digest, observation time, HEAD, merge base, and status. Classify every overlapping Build 1 path and specify whether slice 5 is a prerequisite, dependent PR, or excluded active branch. Keep the checkpoint automation, but make mismatch from this exact initial manifest a stop condition that regenerates impact analysis before Phase 0 or source replay.

### M4 — Provider-token backend failure is still conflated with an invalid credential in the test oracle

**Evidence**

- R2 says auth/store failure returns a closed typed error and activity requires unavailable token authority to be 503, while missing auth is 401 (`origin-main-1d2-reconciliation-plan-r2.md:186-187`, `:214-216`).
- The landed read-only token API distinguishes `valid=false, err=nil` from backend failure (`phase4-coordinator/internal/auth/tokens.go:1448-1472`), but the current provider read helper maps both `err != nil` and `!valid` to the same 401 (`phase4-coordinator/internal/ws/model_admission.go:1890-1897`).
- T15 does not inject token-store error/timeout, and T16 says only “disabled/unavailable token authority/store” without distinguishing a missing interface from an operational validation failure or preserving v1 status behavior (`test-spec-origin-main-1d2-reconciliation-r2.md:259-290`).

**Consequence**

A database outage or timeout is presented as bad provider credentials, causing destructive reauthentication guidance and hiding service health. Changing the shared helper without an explicit compatibility rule can also silently change the existing status-v1 error contract.

**Required correction**

Freeze the error matrix for missing bearer, invalid/revoked/expired token, token validation timeout/backend error, missing read-only capability, admission store failure, and billing store failure for both new endpoints and existing status v1. Inject each error in tests and assert status/code/body/log redaction. State whether a new endpoint-specific authenticator preserves v1 behavior or whether the governing SPEC intentionally changes the common behavior.

## Adequately bounded areas

- The physical Apple Silicon, actual MLX, signed-release, two-operator, receipt, and credit journey remains explicitly blocked unless fresh T22 evidence exists; fixtures are not promoted to hardware qualification.
- Preparation size, stream ceiling, cancellation preservation, non-primary action rejection, corrupt/cross-release/stale feed negatives, and fallback constraints are materially stronger than R1.
- Historical no-extension and six-field route compatibility, no 24-field dirty envelope, immutable delayed-settlement intent, and non-BYOM compatibility are explicitly preserved.
- The R4 prerequisite now names real files and correctly refuses to treat 79 historical passes as acceptance.
- Replay versus re-evaluation is now a real semantic split rather than one overloaded retry claim.
- Production enforcement, rewards/payout activation, release/deployment, merge, spending, secrets, and Build 6 remain outside authorization.

## Gate disposition

The exact R2 plan and test specification do **not** pass the mandatory adversarial plan gate. Their strongest additions identify the right product boundaries, but the economic configuration source, transition-service package boundary, dispatch lifecycle, settlement-state oracle, cursor privacy, readiness history, freshness, live slice-5 snapshot, and token-error behavior are not yet sufficiently specified to implement or verify without inventing authority.

Revise both artifacts, provide exact new digests, and rerun an independent GPT-5.6 Sol high-reasoning review. Implementation remains unauthorized until a review of the exact revised pair reports **0 Critical / 0 High / 0 Medium**.
