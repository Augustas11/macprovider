# SPEC-002 v1.5.0 — Audit findings + R1–R6 dispositions

Three-lane codex audit loop on the SPEC-002 v1.5.0 (coordinator-side
account-scoped reconciliation key) + SPEC-005 v0.3.1 + SPEC-006 v0.9.1
+ IMPL bundle for ISS-211 (follow-up to #196). Converged through
R1 → R2 → R3 → R4 → R5 → R6, fixing as we went.

Audit prompts (per round):
- `specs/AUDIT_ISS_211_R1_*.md`
- `specs/AUDIT_ISS_211_R2_*.md`
- `specs/AUDIT_ISS_211_R3_*.md`
- `specs/AUDIT_ISS_211_R4_*.md`
- `specs/AUDIT_ISS_211_R5_*.md`
- `specs/AUDIT_ISS_211_R6_*.md`

Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R6 conceptual reframe (important for reviewers)

R1–R5 carried a recurring misframing — calling
"`(account_id, request_id)` AttemptN scoping" the *load-bearing fix
for the #211 cross-account collision class*. R5 security caught the
confusion: the buyer-supplied collision class motivating #211 lives
on **external_request_id** (the inbound X-Request-ID, persisted
verbatim), NOT on coordinator-internal **request_id** (server-minted
UUID v4 per buyer call). Two accounts cannot naturally collide on
the latter.

R6 reframes:
- The **load-bearing #211 fix** is the composite
  `(account_id, external_request_id)` reconciliation key
  (request_log.account_id column + partial-NULL composite index).
- The hotpath.go / recovery.go / endpoints.go `(account_id, request_id)`
  scoping under SQLite `IS` semantics is **defense-in-depth**: if
  the same coordinator-internal `request_id` ever recurs across
  rows from different accounts (UUID collision, retry-loop bug,
  future schema change), each account's attempt sequence is derived
  within its own scope rather than misclassified.
- The R4 "Money-path: same-provider cross-account collision" §11
  subsection — and the `TestWriteHotPath_SameProviderCrossAccount...`
  test it pointed at — were artifacts of the misframing and were
  **deleted in R6**. The scenario they pinned (two accounts sharing
  the same internal `request_id` AND routing to the same provider)
  doesn't naturally arise; the test forced an artificial UUID
  collision to exercise the underlying SQL.

The historical R1–R5 framings below are preserved for the
narrative record; readers comparing against the final commit
should treat the R6 reframe as authoritative for current
behavior and SPEC text.

## R1 findings (1 HIGH from security, 1 HIGH from architect, 4 MEDIUM from architect)

### CODE lens

`ZERO FINDINGS`.

### SECURITY lens (1 HIGH)

- **S1 HIGH — Unconditional account header is rejected on default
  non-sticky gateway traffic.** The coordinator's
  `selectProviderExcluding`
  (`phase4-coordinator/internal/buyer/server.go:3896`) treats
  `X-MacProvider-Account` as an internal-routing header gated by
  `internalBearerAuthorized`. The R1 gateway change hoisted
  `X-MacProvider-Account` out of the sticky conditional but left
  the upstream `Authorization` bearer inside, so every non-sticky
  chat forward would have hit the coordinator with the account
  header but no bearer and 400'd as `invalid_request`.
  **R2 fix:** the Authorization bearer is hoisted alongside the
  account header — same pair the sticky path already sent. SPEC-002
  v1.5.0 change-log + SPEC-006 v0.9.1 change-log updated to record
  the bearer-pairing requirement. Integration test
  `TestStrangerKeyOpenAIChatUsageFlow` assertion updated to
  expect `Bearer operator-key` (the configured upstream bearer)
  and to guard that buyer mp_-keys are not forwarded.

### ARCHITECT lens (1 HIGH, 4 MEDIUM)

- **A1 HIGH — `recovery.go` still derives attempt identity with
  unscoped `request_id`.** Same money-path class as the
  `hotpath.go` AttemptN fix, but on the startup/nightly
  reconciliation path. Cross-account `request_id` collisions
  would misclassify legitimate first attempts as retries or as
  ambiguous.
  **R2 fix:** Orphan-detection subquery, `prior`-attempt
  subquery, and `same_request_count` subquery in
  `phase4-coordinator/internal/billing/recovery.go` all now scope
  by `(account_id, request_id)` using SQLite `IS` (which compares
  NULL = NULL as true, preserving legacy behavior). New
  regression `TestRecoverLedger_AccountScopedRequestIDCollisionDoesNotQuarantine`
  mirrors the hot-path regression test and passes.
- **A2 MEDIUM — Rollback guidance treats column presence as
  proof of scoped writes.** R1 deploy-ordering text told auditors
  to switch to `(account_id, external_request_id)` based on
  `PRAGMA table_info(request_log)`; that misclassifies
  rollback-window rows (column present, writer didn't populate).
  **R2 fix:** Deploy-ordering text reworked to use row-level
  `account_id IS NOT NULL` as the gate, with explicit narrative
  on the three NULL-account_id row sources.
- **A3 MEDIUM — Cross-PR pointer not merge-order safe.** R1
  text claimed SPEC-007 §6.4 v0.2.1 "already records" the
  gateway-side composite-PK addendum, but that exists only on
  PR #221 (issue #212).
  **R2 fix:** Reworded to "once issue #212 / PR #221 merges …
  the two PRs are merge-order independent — the cross-pointers
  describe relative state, not a strict ordering."
- **A4 MEDIUM — Explorer joins remain account-blind without a
  documented deferral.** `explorer/store.go` `SessionDetail` /
  `RecentSessions` join `request_log` by `request_id` only and
  do not return `account_id`. R1 had no in-spec note saying
  this is deferred.
  **R2 fix:** Explicit "Explorer deferral" bullet in v1.5.0
  change-log + a follow-up note in the deploy-ordering paragraph.
  Operators run direct SQL with the composite key for v1.5.0;
  explorer enrichment lands as a separate SPEC-007 follow-up.
- **A5 MEDIUM — §10 D11 cross-service correlation contract
  stale.** R1 spec body added the new contract to §11 / §7.2
  but left §10 D11 describing the pre-v1.4.2 model.
  **R2 fix:** D11 now carries two encodings: the pre-v1.5.0
  inherited text (clearly marked superseded) and the new v1.5.0
  encoding naming `external_request_id`, `account_id`, and the
  composite reconciliation key.

## R2 convergence

All six in-scope findings (S1, A1, A2, A3, A4, A5) fixed in this
PR. R2 codex audit not re-run on R2 fixes alone because:

- S1's fix is mechanical (one-line gateway change to hoist
  bearer alongside account header) with directly-verifiable
  contract: every chat forward now carries the bearer, the
  coordinator's `internalBearerAuthorized` check passes, and
  the integration test asserts the exact forwarded header value.
- A1's fix is structural SQL scoping (three subqueries) with
  per-fix regression test (`TestRecoverLedger_AccountScoped...`)
  AND the existing `TestRecoverLedger_*` suite still passes.
  Both pass + legacy-behavior preservation via SQLite `IS NULL`
  semantics is verifiable by inspection.
- A2–A5 are documentation refinements that codify the boundary
  audit already identified; re-auditing for the same lens would
  surface the same text it just suggested.
- If reviewer disagrees, R2 audit prompts are persisted as
  `specs/AUDIT_ISS_211_R1_*.md` and one `omc ask codex` away.

## Follow-up tracking issue

Recommended single follow-up issue covering the explicit
deferrals from this audit:

> Title: SPEC-002/SPEC-007 explorer + reconciliation follow-ups
>         from ISS-211 audit
>
> 1. Coordinator `explorer/store.go` `SessionDetail` /
>    `RecentSessions`: surface `request_log.account_id` and
>    accept optional `?account_id=` to scope joins for
>    cross-account audit (parallel to the gateway-side §6.4
>    addendum in PR #221).
> 2. (Optional) Revisit whether D-CROSS-3 / D11 should encode
>    forwarding the account-scoped composite to the provider
>    over `inference_request`, or whether provider-side
>    attribution remains coordinator-internal only.
