# ARC-3 nested-query unwind — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit (code / security /
architect) of the phase4-coordinator nested-cursor refactor for issue
#21 / ARCH-3. Stay narrowly in your lane — code correctness has a
code lane; risk has a security lane; flag overlap as `QUESTIONS`
rather than mixing scopes.

The architect lens cares about: module boundaries, single source of
truth, abstraction altitude, coupling, future-evolution constraints,
cross-spec consistency, anti-pattern entrenchment.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries` (origin/main base: eaae922)
- Files in scope (`git diff origin/main -- phase4-coordinator/`):
  - `phase4-coordinator/internal/billing/store.go`
  - `phase4-coordinator/internal/billing/endpoints.go`
  - `phase4-coordinator/internal/billing/snapshot.go`
  - `phase4-coordinator/internal/billing/recovery.go`
  - `phase4-coordinator/internal/billing/nested_query_regression_test.go`
  - `phase4-coordinator/internal/requestlog/store.go`

## What the change does (operator summary — NOT the audit answer)

Issue #21 / ARCH-3 / 2026-06-10 audit QW-5. Three nested-cursor sites
in billing money-path code deadlocked at `MaxOpenConns(1)`; PR #14
landed cap=1 only for auth + audit (isolated DBs) and was closed
unmerged after CI hung at billing. This branch refactors three sites
to two-pass, catches a 4th in-tx site via the test sweep, introduces
a `snapshotQueryer` interface + `snapshotAtTx` helper, and finally
adds `SetMaxOpenConns(1)` + `SetMaxIdleConns(1)` to
`requestlog.OpenStore`.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Single source of truth on connection-pool policy
- Three stores now cap at 1 (auth, audit, requestlog). The fourth
  conceptual store (billing) reuses `requestlog.DB()` via
  `billing.NewStore(reqLogStore.DB())` (see `cmd/coordinator/main.go`
  line ~88). Is the cap-1 policy thus enforced only at the
  requestlog level (good — one site), or is there a code path where
  billing or admission opens its own DB without the cap (bad — drift
  risk)?
- The comment in `requestlog.OpenStore` claims auth + audit already
  cap at 1. Confirm by reading `phase4-coordinator/internal/auth/
  tokens.go` and `phase4-coordinator/internal/audit/store.go`. If
  the cap is at three separate sites, is there an architectural case
  for hoisting it into a shared `sqliteutil.WithCap1Pool(db)` helper?
  (Don't recommend the helper if it would over-engineer; flag the
  three-way duplication as MAJOR/MEDIUM only if it's load-bearing.)

### ARCH-2. The `snapshotQueryer` interface — abstraction altitude
- A new `snapshotQueryer` interface narrowing to `QueryRowContext`
  was introduced so `snapshotAt` and `snapshotAtTx` can share a body.
  Is this the right altitude?
  - PRO: narrow interface; both `*sql.DB` and `*sql.Tx` satisfy it
    without adapter; no leakage outside the snapshot file.
  - CON: precedent — should every `s.db`-vs-`tx` decision in this
    package be unified under one queryer interface, or is one-off
    targeted helpers (like `snapshotAtTx`) the right scope?
- `snapshotQueryer` is unexported (lowercase). Right scope, or
  should it be exported as `billing.Queryer` for cross-helper
  reuse?

### ARCH-3. The pattern this codebase is now committing to
- The two-pass-drain-then-process pattern is now used in three
  billing sites. Is that the canonical "billing reads from rows
  while issuing inner queries" pattern going forward, or is there
  a higher-altitude fix (e.g. JOIN the sub-query into the outer
  query, or use a SQL window-function aggregation)? Trace at least
  one of the three sites — could `providers` express
  `pending_payout_credits` as a JOIN against
  `ledger_payout_ready` instead of an N+1 sub-query? If yes, is
  the two-pass refactor entrenching an anti-pattern that should
  have been a SQL fix?

### ARCH-4. The `RecoverLedger` 4th site — was the boundary right?
- `RecoverLedger` calling `s.snapshotAt` from inside its own tx
  was a latent bug at cap=1. The fix added a tx-aware variant.
  But the architectural question is: why was `snapshotAt` reaching
  into `s.db` directly in the first place when its callers are
  sometimes inside a tx? Is there a deeper boundary violation
  here (e.g. the snapshot abstraction should ALWAYS receive a
  queryer, never assume a particular handle)?

### ARCH-5. Cap=1 vs SQLite write serialization — is the cap right?
- SQLite supports ONE writer at a time. The Go pool cap of 1 makes
  the Go-pool serialize writes (and reads, which is over-strict).
  Alternative: cap=1 for the WRITER pool, but allow N readers via
  WAL — Go's `database/sql` doesn't natively split, but a second
  `*sql.DB` opened read-only is the idiomatic shape.
- Is the cap=1 decision right for this stack, or should the
  architectural correct answer be a separate read-only DB handle?
  (Don't recommend a heavyweight refactor if cap=1 is good enough;
  flag only if cap=1 is going to be a measurable production
  bottleneck.)

### ARCH-6. Test artifact placement
- The new `nested_query_regression_test.go` lives in
  `internal/billing/`. It tests behavior that spans
  requestlog + billing (cap=1 is at requestlog; the deadlock is
  in billing). Is `internal/billing/` the right location, or
  should it live in `internal/requestlog/` (where the cap lives),
  or in a new cross-package test? The current placement uses
  the existing `newRequestAndBillingStores` helper — convenient,
  but a follow-on contributor who deletes the requestlog cap
  won't see the test fail unless they run the billing package.

### ARCH-7. Cross-spec consistency
- Does any SPEC normatively document the cap=1 policy on
  `requestlog.OpenStore`? Should SPEC-005 (request_log /
  reconcile / billing) mention the pool-cap discipline so a
  future contributor reading the spec alone sees the constraint?
- The issue notes that audit + auth caps were never normatively
  documented either. Is this drift acceptable, or does it
  warrant a one-line SPEC-005 amendment in this PR?

### ARCH-8. The bundle-PR vs split-PR question
- This PR bundles: 3 nested-cursor refactors + 1 in-tx fix + the
  requestlog cap + a regression test + a new helper interface.
  Per [[feedback-bundle-spec-impl-one-pr]] (incremental SPEC + IMPL
  bundle is OK) — but this isn't a SPEC+IMPL pair; it's all IMPL.
  Is the bundle right (atomically buys cap=1 enforcement), or
  should the cap=1 land as a follow-up after the four refactors
  are merged and verified independently?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write the report to
`specs/ARC_3_NESTED_QUERIES_ARCHITECT_audit.md` (round suffix on
follow-ups: `_ARCHITECT_r2_audit.md`).

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE`
