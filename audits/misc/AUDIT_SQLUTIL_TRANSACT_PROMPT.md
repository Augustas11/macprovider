# AUDIT: `sqliteutil.Transact` helper + 6 money-path call-site conversions

## Change under review

Branch: `refactor/sqlutil-transact` (base `origin/main` = `3537154`).

**New file:**

- `phase4-coordinator/internal/sqliteutil/transact.go` (~62 LoC): defines
  `Transact(ctx, db, fn(ctx, *sql.Conn) error) error`. Reserves a single
  `*sql.Conn`, issues `BEGIN IMMEDIATE`, invokes `fn`, then `COMMIT` on nil
  error or `ROLLBACK` on non-nil error. **`ROLLBACK` is issued with
  `context.Background()`, never the caller's ctx** — this matches the
  invariant from every hand-rolled site being replaced.

**Converted call sites (6):**

1. `phase4-coordinator/internal/auth/tokens.go` `MintProviderTokenAppTrack`
   (App-track token issuance, SPEC-003 FR-C9, SPEC-026)
2. `phase4-coordinator/internal/auth/tokens.go` `MintPairOTRefresh`
   (pair-OT refresh, SPEC-014, rate-limited)
3. `phase4-coordinator/internal/billing/hotpath.go` `WriteHotPath` — the
   BIG one. Four early-COMMIT-and-return branches in the original
   (attempt_n reconciliation, quarantine attempt-1, cache-quarantine,
   happy path).
4. `phase4-coordinator/internal/billing/hotpath.go`
   `WriteRequestLogWithIdentity` (identity-snapshot writeback)
5. `phase4-coordinator/internal/billing/store.go` `SetForceVoidEnabled`
   (SPEC-005 §11.6 force-void flag audit; test
   `TestSetForceVoidEnabledRollsBackOnAuditFailure` at
   `quarantine_test.go:1351` is the load-bearing regression guard)
6. `phase4-coordinator/internal/billing/snapshot.go` (config-snapshot +
   optional flag-change audit atomic write)
7. `phase4-coordinator/internal/billing/settlement_receipts.go`
   `applySettlementReceiptVerdict` (SPEC-022 receipt idempotency +
   settlement outcome)

**Sites NOT converted (justified):**

- `phase4-coordinator/internal/billing/quarantine.go:140`
  (`handleForceVoid` HTTP handler): 4 different HTTP response paths
  (404, validation error, 409 already-resolved, 500, 200) interleaved
  with the tx and requires re-reading via `s.db` on the already-resolved
  409 path AFTER releasing the conn (MaxOpenConns=1 deadlock avoidance,
  see comment at `:184-188`). Converting cleanly requires restructuring
  the whole handler, not the tx. Kept inline.
- `phase4-coordinator/internal/requestlog/store.go:883`
  (`BackfillAttemptNDryRun`): the current pattern always ROLLBACKs
  (never COMMITs). `sqliteutil.Transact` commits on nil return, so it
  is the wrong shape for a dry-run.
- `phase5-gateway/internal/storage/sqlite/store.go:1770`
  (`beginImmediate`): gateway already has its own `immediateTx` object
  abstraction used by 12 call sites; no consolidation win.

Diffstat (excludes the new `transact.go` file):

```
 phase4-coordinator/internal/auth/tokens.go            | 205 +++++++-------
 phase4-coordinator/internal/billing/hotpath.go        | 299 +++++++++------------
 phase4-coordinator/internal/billing/settlement_receipts.go | 124 ++++-----
 phase4-coordinator/internal/billing/snapshot.go       |  52 ++--
 phase4-coordinator/internal/billing/store.go          |  34 +--
 5 files changed, 308 insertions(+), 406 deletions(-)
```

Net -98 LoC in call sites + 62 LoC in the new helper = **-36 LoC net**,
plus **one place** now owns BEGIN IMMEDIATE / ROLLBACK-on-cancel
semantics for the money-path.

## Semantics-preservation invariants each lane MUST verify

1. **Rollback context isolation.** The hand-rolled pattern uses
   `context.Background()` for the rollback, so cancellation of the
   caller's ctx after a partial write does not leave the tx dangling.
   `sqliteutil.Transact` MUST preserve this. Verify at
   `sqliteutil/transact.go:52`.
2. **Commit-then-publish ordering** in `SetForceVoidEnabled`. The
   `forceVoidEnabled.Store(newValue)` MUST NOT execute unless the audit
   INSERT durably committed. Reg test
   `TestSetForceVoidEnabledRollsBackOnAuditFailure` covers this;
   verify the refactor keeps `Store` outside the callback.
3. **Return-value plumbing.** `MintProviderTokenAppTrack` and
   `MintPairOTRefresh` return non-error data through a closure-captured
   local var, set inside the callback before returning nil. Verify no
   path returns nil-error-with-zero-value (would leak an empty token
   or empty PairOTRefreshResult to a caller expecting success).
4. **Early-return branches in `WriteHotPath`.** The original had four
   `COMMIT + committed = err == nil + return err` sites at
   lines 73, 132, 177, 218 (pre-refactor). Each is now `return nil`
   inside the callback. Verify no branch dropped a mutation between
   the original explicit COMMIT and the callback return.
5. **`syncVerifiedReceiptLedgerCreditForAttemptTx` participation.** In
   both `WriteHotPath` and `applySettlementReceiptVerdict`, this
   helper runs INSIDE the tx. Verify the refactored callback still
   passes `conn` (not `s.db`) to that helper — passing `s.db` would
   deadlock at `MaxOpenConns=1` because the tx is holding the writer.
6. **Error-wrapping regression.** `store.go:SetForceVoidEnabled`
   previously wrapped BEGIN/COMMIT errors with `fmt.Errorf("begin
   immediate for flag-change audit: %w", err)` and similar. The
   refactor moves those inside the callback (only the INSERT is
   wrapped now). Verify no test asserts the old error strings.
7. **`applySettlementReceiptVerdict` early-return** at the
   `found && existing.Closed` branch preserved the state via
   `existing.IdempotencyStatus = ...`, hydration, audit INSERT, and
   COMMIT-with-return. Verify the refactored callback assigns
   `outcome = existing` before `return nil` (not
   `outcome = state` — different variables).

## What each lane should check

### Lane A — code

- Are the callback return values ever nil-on-partial-success? (i.e.
  data assigned to an outer var, then a subsequent error, then a
  second early-return that leaves the outer var stale).
- Does the callback ever call a helper that expects `*sql.DB` rather
  than `*sql.Conn` (silent second-conn acquisition → deadlock at
  MaxOpenConns=1)?
- Are there any `defer` orderings that changed (e.g. a deferred close
  that used to run before ROLLBACK now runs after)?
- Byte-equivalence check: does the helper's BEGIN/ROLLBACK/COMMIT
  sequence match what each hand-rolled site did?

### Lane B — security

- Does the `Transact` helper leak a token or receipt state through
  the closure on a rollback path? (Return-value plumbing in
  `MintProviderTokenAppTrack` / `MintPairOTRefresh`.)
- Does the SetForceVoidEnabled path publish the atomic flag before
  the audit row is durable, under any refactored code path?
- Is the ROLLBACK-with-Background-ctx invariant preserved so a
  cancelled request cannot leave the write lock held?

### Lane C — architect

- Is `internal/sqliteutil` the right home for this? (`dsn.go` already
  lives there; `WithPragmas` is byte-duplicated with gateway on
  purpose per ARCH-5). The helper is coord-only for now — flag if
  gateway should also adopt (my read: no, gateway has
  `beginImmediate`+`immediateTx` object-style already).
- Should the 3 skipped sites be tracked as follow-up work
  (quarantine.go handler, requestlog dry-run, gateway parity)?
- Does the abstraction pay for itself at 6 call sites, or is this
  premature? (My read: yes — the ROLLBACK-with-Background-ctx
  invariant is subtle enough that centralizing it is worth the
  callback indirection, and the 4 early-COMMIT branches in
  `WriteHotPath` reduced from 4× `COMMIT + committed = err == nil +
  return err` to 4× `return nil`.)

## Deliverable per lane

Plain-text report, same format as previous audits:

- **Verdict**: `PASS 0 CRITICAL / 0 HIGH / 0 MEDIUM` or a list of findings.
- **Findings**: `SEVERITY | file:line | one-sentence claim | evidence`.
- **Recommendation**: `merge` / `merge after LOW fixes` / `hold`.

Money-path bar per repo convention: 0 CRITICAL, 0 HIGH, 0 MEDIUM
across all three lanes before merge. LOW findings ship with PR-body
documentation.
