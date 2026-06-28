# Stage 2 — hand-evaluation of deepsec pilot findings

**Scope:** 8 novel findings from `audits/2026-06-28/deepsec-pilot/SUMMARY.md`
(Findings #1 and #4 are pre-classified TP-known per the handoff brief —
they correlate with commit `9bd77f4 Close audited billing and idempotency
gaps`).
**Method:** opened each finding's named source line, traced the claim
against current `phase4-coordinator/internal/billing/` HEAD, cross-checked
`audits/2026-06-{03,10,24}/`, `specs/SPEC-005-*`, `specs/SPEC-016-*`, and
the ARC-3 nested-queries audit set for prior coverage.

## Verdict table

| # | File:line | Claim | Classification | Reasoning summary |
|---|---|---|---|---|
| 1 | `endpoints.go:303,343,353,357` | Reconcile fallback bypasses 9bd77f4's completion-clamp | TP-known | Pre-classified per brief; generalization of 9bd77f4 |
| 2 | `endpoints.go:353-355` | `buyerEquivalentCredits` silently `continue`s on `snapshotAt` errors, parent records `status='complete'` | TP-novel | ARC-3 SEC audit Q3 explicitly green-lit this path on the basis that errors propagate — but only `time.Parse` and `byteEstimatedLedgerGross` return; `snapshotAt` uses `continue`. Real gap that survived a prior audit asking exactly this question. |
| 3 | `endpoints.go:486-490` (`h.sum`) | `h.sum` returns 0 on DB error, summary returns 200 with zeroed totals, earnings returns 404 | TP-known | ARC-3 SECURITY audit (`specs/ARC_3_NESTED_QUERIES_SECURITY_audit.md` SEC-2) flagged the exact `endpoints.go:492-496` `h.sum` swallow-error pattern and recommended `sumErr`. Fix landed only in the providers handler (commit `4f73f5d`, PR #175); summary / earnings / lastPayout / modelsServed / rateCardExcerpt still use `h.sum` or `return nil/empty` on error. Class in backlog; broader sweep is the novel scope. |
| 4 | `formula.go:119,136,141` | `prompt_tokens` not clamped against coordinator estimate | TP-known | Pre-classified per brief; symmetric complement of 9bd77f4 |
| 5 | `payout.go:28-37` | `ClaimPayoutReady` accepts empty `payoutExternalID` / `payoutCurrency`, writes NULL, terminal-status trigger prevents repair | TP-known | SPEC-016 §4.3 step 8 (line 1309-1320) explicitly mandates the caller pass non-empty `"USDC-BASE"` and §7.4 reconciliation surfaces NULL `payout_currency` on `consumed` rows as a separate failure class. Spec acknowledged the same concern and chose caller-discipline + post-hoc detection over primitive-side validation. |
| 6 | `recovery.go:446` (`quarantineExistingLedgerForRequestAttemptTx`) | Helper lacks `settled=0 AND settlement_id IS NULL` filter; `invalid_usage_tokens` / `missing_config_snapshot` / `ambiguous_attempt_n` branches can quarantine settled rows | TP-novel | Confirmed at recovery.go:446-470: only `quarantined = 0` filter. The settled-row guard at reconcileExistingCreditTx:406 is only reached on the recomputation-mismatch path; early branches at lines 117, 159, 213 skip it. Not covered in any prior audit; ARC-3 looked at `RecoverLedger` for deadlock only. |
| 7 | `recovery.go:112-114` | `time.Now().UTC()` substituted for unparseable `ts_utc`; nondeterministic snapshot selection | TP-novel | Confirmed at recovery.go:112-115. Precondition is narrow (request_log writes via `Insert` use a valid `time.Time`, so only legacy/manual/corrupt rows hit this), but the fallback path is real and silently selects a wrong-window rate-card snapshot. Not covered. |
| 8 | `settlement.go:23,37,61,120` | RFC3339Nano lexicographic compare of `ts_utc TEXT` vs window-end cutoff lets `.5Z` rows sort before `Z` rows | TP-novel | Confirmed: `NextMondayUTC` returns midnight (no fractional), formatted windowEnd is `2026-06-08T00:00:00Z`. `.` (0x2E) < `Z` (0x5A) so `2026-06-08T00:00:00.5Z` lexically precedes the boundary. The hazard CLASS was documented in `audits/2026-06-10/REMAINING_WORK.md` lines 31, 126 — but scoped only to `phase4-coordinator/internal/requestlog/store.go` retention pruning, framed "Low risk now; degrades as request_log grows." The settlement.go instance was not in backlog; it has a materially worse blast radius (provider payout window vs. retention prune). |
| 9 | `settlement.go:152` | `StartWeeklySettlement` discards `RunSettlement` error; weekly payout job fails silently | TP-known | Same pattern flagged in `audits/2026-06-03/ARCHITECTURE_AUDIT.md` line 103 for `StartNightlyReconcile`'s `_ = s.RecoverLedger(...)` and called out as a recurring theme at line 274 ("money-path durability is eventually-consistent and best-effort, with no alarming on the degradation rate") and line 278 ("discarded settle errors are silent"). Class in backlog; this is the weekly-settlement instance that 2026-06-03 missed. |
| 10 | `store.go:73` | `UNIQUE(request_id, attempt_n, provider_id)` permits multiple non-quarantined rows for same (request_id, attempt_n) across different provider_ids | TP-novel | The schema literal is consistent with SPEC-005 D10's chosen key, but the application logic (recovery's `ambiguous_attempt_n` quarantine at recovery.go:212, hot-path deterministic provider derivation) implements "one provider per (request_id, attempt_n)". The storage boundary doesn't enforce that. SPEC-005-r2-audit X-2 covered the related `request_log` row-uniqueness gap but did not address `ledger_request_credits`. Defense-in-depth gap; no remote write path, but real for internal recovery/import/admin regressions. |

## Per-finding evaluation

### Finding #1 (HIGH_BUG, endpoints.go reconcile fallback) — TP-known
Pre-classified per the handoff brief. Generalization of commit `9bd77f4`'s
`billableCompletion` clamp to the `buyerEquivalentCredits` reconcile
fallback path that 9bd77f4 did not touch. Not re-evaluated here.

### Finding #2 (HIGH_BUG, endpoints.go reconcile silent skip) — TP-novel
At endpoints.go:330-360 the loop body propagates errors from
`time.Parse` (line 336) and `byteEstimatedLedgerGross` (line 348) via
`return 0, err`, but the `h.store.snapshotAt(ctx, ts)` call at line 353
uses `continue` on error. The outer `reconcile` handler treats a nil
return from `buyerEquivalentCredits` as success and inserts a
`ledger_reconciliation_runs` row with hard-coded `status='complete'` at
endpoints.go:259. `specs/ARC_3_NESTED_QUERIES_SECURITY_audit.md` Q3
specifically asserted "the second-pass `buyerEquivalentCredits` error
path returns before [...] inserts `ledger_reconciliation_runs`, so no
partial reconciliation row is committed when per-row work fails" — that
assertion is overbroad. The recovery path handles `snapshotAt` failure by
quarantining (`missing_config_snapshot`, recovery.go:159); the admin
reconcile path silently undercounts. Real asymmetry. Defense-in-depth
fix: change `continue` to a quarantine row + counter increment OR
propagate the error and let the run record `status='failed'`.

### Finding #3 (BUG, endpoints.go h.sum) — TP-known
At endpoints.go:486-490, `h.sum` discards the error and returns 0. The
`/admin/ledger/summary` handler (lines 97-112) builds every field via
`h.sum` and unconditionally writes 200. `/providers/{id}/earnings` uses
`h.sum` for both the provider-existence check at line 427 (DB error →
404) and the total/current/fault values at lines 444-450. `lastPayout`,
`modelsServed`, `rateCardExcerpt`, `latestShareBps` all return
empty/nil/0 on error. `specs/ARC_3_NESTED_QUERIES_SECURITY_audit.md`
SEC-2 explicitly recommended "Use `sumErr` in the second pass" for the
providers handler — that fix landed in PR #175 (commit `4f73f5d`) but
was scoped to the providers N+1, not swept across the other endpoints.
The endpoints.go:138-142 comment block written for that PR even
acknowledges "h.sum swallows errors" was a problem and references the
specific shape that was fixed. Class is in backlog; broader instance
remains. Lower-severity finding (observability, not money loss).

### Finding #4 (HIGH, formula.go prompt_tokens unbounded) — TP-known
Pre-classified per the handoff brief. Symmetric complement of `9bd77f4`'s
completion-side `billableCompletion` clamp. Not re-evaluated here.

### Finding #5 (HIGH_BUG, payout.go ClaimPayoutReady) — TP-known
Confirmed at payout.go:28-40: the UPDATE does not validate
`payoutExternalID` or `payoutCurrency` before passing them through
`nullString()` (store.go:323-328), which converts `""` to
`sql.NullString{Valid:false}` (NULL). `ledger_payout_ready` schema
(store.go:111-117) allows both columns NULL, and
`trg_lpr_terminal_status_guard` (store.go:121-126) prevents repair once
status is `consumed`. SPEC-016 v0.1 §4.3 step 8 (line 1309-1320)
acknowledges this exact concern: "`payoutCurrency` MUST be the literal
string `\"USDC-BASE\"` (never empty, never NULL). IMPL MUST add a unit
test asserting the literal is passed; the §7.4 reconciliation surfaces a
NULL `payout_currency` on a `consumed` row as a separate failure class
to catch any regression." Spec consciously chose caller-discipline +
reconciliation-detection over primitive-side validation. Deepsec's
recommendation is a reasonable defense-in-depth tightening but the bug
is already in the spec's awareness.

### Finding #6 (HIGH_BUG, recovery.go quarantine settled rows) — TP-novel
Confirmed at recovery.go:446-470: the UPDATE filters only
`quarantined = 0`, not `settled = 0 AND settlement_id IS NULL`. Callers
that bypass `reconcileExistingCreditTx`'s settled-row guard
(recovery.go:406): `invalid_usage_tokens` branch (line 117),
`missing_config_snapshot` branch (line 159), `ambiguous_attempt_n`
branch for `attemptN > 1` (line 213). The deepsec revalidation traces a
concrete scenario: a settled row whose source `request_log` row has
invalid usage tokens hits the line-117 branch and gets retroactively
quarantined while its `payout_ready` row remains intact. ARC-3 audited
`RecoverLedger` for deadlock only; SPEC-005's audits (r1, r2) did not
cover this. Real corruption scenario for the recovery path; trigger
requires either malformed legacy request_log rows or admin operations on
the rate-card snapshot table after a settlement window closes. Fix is
~1 line per call site or one predicate added to the helper.

### Finding #7 (BUG, recovery.go time.Now() fallback) — TP-novel
Confirmed at recovery.go:112-115:
```go
ts, err := time.Parse(time.RFC3339Nano, tsText)
if err != nil {
    ts = time.Now().UTC()
}
```
That `ts` is then passed to `snapshotAtTx`, `HotPathInput.TSUtc`,
`insertQuarantineTx`, and `insertRequestCreditTx`. Same persisted
request_log row recovered at different wall-clock times can select
different rate-card snapshots. `requestlog.Insert` writes a valid
formatted time.Time so there is no public path to inject malformed
`ts_utc` — precondition is narrow (legacy data, manual repair, schema
drift). Not in any audit or spec. Lower severity. Fix is one line: treat
parse failure as a deterministic quarantine.

### Finding #8 (HIGH_BUG, settlement.go RFC3339Nano lex compare) — TP-novel
Confirmed: `RunSettlement` (settlement.go:23,37,61,120) compares
`ts_utc TEXT` against `windowEnd.UTC().Format(time.RFC3339Nano)`.
`NextMondayUTC` returns midnight UTC (no fractional seconds), so
windowEnd is `2026-06-08T00:00:00Z`. A row written at
`2026-06-08T00:00:00.000000001Z` (chronologically just after the
boundary) compares lexicographically less than the boundary because
`'.'` (0x2E) sorts before `'Z'` (0x5A). That row is then included in
the prior settlement window and marked `settled=1`. The hazard CLASS
was documented at `audits/2026-06-10/REMAINING_WORK.md` line 126: "RFC3339Nano
writes are variable-width (`.` 0x2E < `Z` 0x5A) so lexicographic compare
is silently wrong at fractional-second boundaries. PERF-3 batched-DELETE
shipped, but the index is still defeated by julianday(). Low risk now;
degrades as request_log grows." That entry scoped the concern strictly
to `phase4-coordinator/internal/requestlog/store.go` retention pruning.
The settlement.go application of the same class was not in backlog and
has materially worse blast radius (provider payout window assignment vs.
retention prune wall-clock skew). Strictly TP-novel because the
settlement-specific instance is unaddressed; the class is recognized
elsewhere. The deepsec agent's own revalidation note caught the
requestlog pruner using `julianday(...)` for this reason — strong recall
signal. Fix is store-as-fixed-width or use `julianday()` in the
settlement queries.

### Finding #9 (BUG, settlement.go silent RunSettlement) — TP-known
Confirmed at settlement.go:152: `_ = s.RunSettlement(ctx, cfg, start, end)`.
`StartWeeklySettlement` has no logger, no status sink, no retry signal;
on failure it returns to the timer loop and the next attempt is the
following Monday. Exact same `_ = ...` swallow-pattern flagged in
`audits/2026-06-03/ARCHITECTURE_AUDIT.md` line 103 for
`StartNightlyReconcile`'s `_ = s.RecoverLedger(...)` and called out as a
recurring theme at lines 274 and 278. Class in 2026-06-03 backlog; the
specific weekly-settlement instance was missed.

### Finding #10 (HIGH_BUG, store.go missing partial unique) — TP-novel
Confirmed: store.go:73 — `UNIQUE(request_id, attempt_n, provider_id)`,
not a partial unique on `(request_id, attempt_n) WHERE quarantined = 0`.
The literal schema is consistent with SPEC-005 D10's stated key choice,
but the application enforces a tighter invariant: recovery's
`ambiguous_attempt_n` quarantine (recovery.go:212) and hot-path
deterministic single-provider derivation both behave as if
`(request_id, attempt_n)` maps to one provider. The deepsec agent
correctly notes the storage boundary doesn't enforce what application
code does. SPEC-005-r2-audit X-2 covered an adjacent gap (`request_log`
row uniqueness) but punted it to a future SPEC-002 patch; it did not
address `ledger_request_credits`. Severity is moderate because no remote
write path exposes raw ledger inserts and the application logic
quarantines ambiguous cases — real risk is internal recovery/import/admin
regressions. Defense-in-depth fix.

## Tally

| Classification | Count |
|---|---|
| TP-novel | 5 (#2, #6, #7, #8, #10) |
| TP-known | 5 (#1, #3, #4, #5, #9) |
| FP-plausible | 0 |
| FP-noise | 0 |

- TP-novel ≥ 1 ✓
- (TP-novel + TP-known) / 10 = 100% ≥ 30% ✓

## Decision recommendation: **Adopt**

The 100% real-rate against a money-path package, with 5 genuinely novel
real bugs (no FPs), exceeds the Adopt threshold by a wide margin. Two of
the TP-novel findings (#6 settled-row corruption, #8 settlement-window
skew) are correctness defects on the highest-blast-radius code path
(weekly payout). One TP-novel (#2) caught a real gap that a previous
codex audit pass had explicitly green-lit. That's the strongest possible
signal: deepsec catches real bugs that focused audits miss.

The TP-known findings are also useful — they generalize known patterns
(silent `_ =` settle errors, `h.sum` swallow-error) to instances the
focused audits missed. Lower-severity but high-recall.

### Adoption scope

Scoped per `AGENTS.md` §3 sensitive paths. Both phase4 and phase5
money/auth packages:

| Directory | Files (total) | Est. cost @ $0.72/file |
|---|---|---|
| `phase4-coordinator/internal/billing/` | 12 | $8.64 (Stage 1 baseline: $9.30) |
| `phase4-coordinator/internal/buyer/` | 18 | $12.96 |
| `phase4-coordinator/internal/auth/` | 3 | $2.16 |
| `phase4-coordinator/internal/requestlog/` | 2 | $1.44 |
| `phase5-gateway/internal/router/` | 17 | $12.24 |
| `phase5-gateway/internal/auth/` | 4 | $2.88 |
| **Total** | **56** | **~$40** |

Wall-clock at Stage 1 burn-rate (12 files / 17 min ≈ 1.4 min/file) is
~80 min for a full sensitive-path sweep. Comfortably inside one Plus
5-hour window with headroom for revalidation.

### Operational shape

Three structural decisions, in priority order:

1. **`--files-from` direct mode, not custom matcher pack.** The Stage 1
   matcher-recall floor (1/12 files flagged by default scan, ~8%
   recall on Go money-path) makes the default `scan → process` pipeline
   effectively inert. The fix is direct mode with a curated per-package
   manifest (`find <dir> -maxdepth 1 -name '*.go' -not -name '*_test.go'`),
   not a custom Go-matcher pack. Reasons: (a) deepsec docs flag
   `writing-matchers.md` as a non-trivial workflow needing TP corpus to
   seed; (b) `--files-from` is documented behavior and gives full,
   predictable coverage with no recall guesswork; (c) the 56-file
   universe is small enough that per-file cost dominates regardless of
   matcher gating; (d) money-path sensitive-paths are stable — the
   manifest doesn't churn.

2. **Cross-model revalidation pass.** Stage 1's "10/10 TP" is
   codex-self-confirmed. For adoption-grade decisions, run a second
   `--agent claude` revalidation against the same finding set. The
   Stage 1 caveat (b) — same-model revalidation will rubber-stamp
   same-model errors — is load-bearing for the credibility of any
   finding the next sweep produces. A claude pass would have either
   raised confidence on the 100% TP rate or surfaced the FP we should
   have flagged.

3. **Trigger discipline: PR-diff scans on the 6 sensitive paths, not
   monthly full-tree.** Run deepsec when a PR touches one of the
   sensitive paths; manifest is the changed files plus their adjacent
   reads, not the whole package. Stage 1's 12-file pass was a
   thorough-package sweep; PR-diff would typically be 3-8 files, ~$2-6
   per scan. Adds one CI lane on the sensitive-path changeset.

### Out of scope for this adoption

- Non-money-path Go code (`phase4-coordinator/internal/{pool,config,...}`,
  `phase5-gateway/internal/{storage,...}`). Diminishing returns: no
  ground-truth corpus, lower blast radius, and the Stage 1 recall-on-Go
  finding suggests we'd need direct-mode-everything which gets expensive
  fast.
- Swift/TypeScript packages (CLI, console, portal). Default matcher set
  has reasonable React/TS coverage; the matcher-recall problem is Go-
  specific.
- d-inference references — clean-room boundary per AGENTS.md §4.
