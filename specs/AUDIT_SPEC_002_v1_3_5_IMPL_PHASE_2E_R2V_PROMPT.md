# R2 closure-verification audit — SPEC-002 v1.3.5 Phase 2E

Operator-paste prompt for Codex GPT-5 to perform a focused
**closure-verification** review of commit `9bfc4a8` (the R2 fix
commit that landed on top of `c8aba39`), confirming each of the 4
findings from the Phase 2E R1 audit at
`.omc/artifacts/ask/codex-execute-the-phase-2e-mid-stream-audit-prompt-at-specs-audit--2026-06-07T04-57-28-891Z.md`
is genuinely closed AND that the R2 changes did not introduce new
defects.

Mirrors the 2B R2V / 2C R2V pattern. Last targeted audit before the
broader pre-merge audit across all 5 phases.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~12-20 min
(tightly scoped surface — 4 small fixes).
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an R2 closure-verification audit on commit
`9bfc4a8` in /Users/augstar/macprovider-poc, branch
`fix/spec-002-v1-3-5-coordinator`. This commit applies 4 fixes
addressing the R1 audit findings on commit `c8aba39` (Phase 2E —
audit_log infrastructure + operator_model_swap emitter).

Your task has TWO halves:
  A. Verify each of the 4 R1 findings is genuinely closed by 9bfc4a8.
  B. Sniff for new findings introduced by 9bfc4a8 itself.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state:
- de41380 (2A) through c8aba39 (2E): full SPEC-002 v1.3.5 implementation
- 9bfc4a8 (2E R2): **THIS commit — under closure-verification**

R1 audit verdict for c8aba39 was PROCEED-TO-PRE-MERGE-AUDIT with:
- 0 CRITICAL, 0 MAJOR
- 4 MINOR — payload `ts` precision (code:1.1), E2E loading_window_ms
  value assertion (code:1.2), prune cutoff-boundary test (code:1.3),
  Store.DB() accessor doc comment (arch:1.1).

R2 (9bfc4a8) claims to close all 4 with inline fixes by Claude.

## Required reading (in this order)

1. The R1 audit artifact at
   `.omc/artifacts/ask/codex-execute-the-phase-2e-mid-stream-audit-prompt-at-specs-audit--2026-06-07T04-57-28-891Z.md`
   — read the full Findings section.

2. The R2 commit via `git show 9bfc4a8`. Read the full diff.

3. The R2 commit message (full body, including the rationale for
   each of the 4 fixes).

4. The locked spec sections cited in the R1 findings:
   - `specs/SPEC-002-coordinator.md` v1.3.5 §7.10.1 R-7.10.2
     (ts_utc RFC3339 UTC requirement), §7.10.2 R-7.10.4 (payload
     schema), §7.10.2 R-7.10.6 (loading_window_ms semantics).
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.6
     example payload (subsecond precision in the locked `ts`
     example).

5. The current source after R2:
   - `phase4-coordinator/internal/audit/store.go`
   - `phase4-coordinator/internal/audit/store_test.go`
   - `phase4-coordinator/internal/audit/swap_event.go`
   - `phase4-coordinator/internal/ws/server_test.go`

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Part A — R1 closure verification

For each R1 finding, produce a verdict from {CLOSED, NOT-CLOSED,
PARTIAL}. Cite the file:line that contains the fix and the test
name (or comment) that proves the closure.

### A1 — [code:1.1] MINOR — payload `ts` precision

**R1 finding:** `payload.ts` used `time.RFC3339` (second precision);
`audit_log.ts_utc` used `time.RFC3339Nano`. Inconsistent precision
weakens forensic correlation for same-second swaps.

**R2 claimed fix:** Switched payload `ts` to RFC3339Nano with a
code comment citing SPEC-002 §7.10.1 R-7.10.2 + SPEC-011 §3.6 (the
locked example shows subsecond precision).

**Verify:**
- Read swap_event.go around the swapPayload construction. Confirm
  `event.CompletedAt.UTC().Format(time.RFC3339Nano)` is used (not
  `time.RFC3339`).
- Confirm the rationale comment cites BOTH the schema rule
  (R-7.10.2) AND the locked-example precision (SPEC-011 §3.6).
- Run `TestBuildSwapPayloadTSIsRFC3339UTC`. Confirm it still
  parses the `ts` field via `time.Parse(time.RFC3339, ...)` — the
  RFC3339Nano output MUST remain RFC3339-parseable (it is, as
  RFC3339Nano is a superset).
- Cross-check that the same RFC3339Nano format is used for the
  `ts_utc` column in store.go's Insert at the
  `ts.UTC().Format(time.RFC3339Nano)` site. Both timestamps now
  match in precision.

### A2 — [code:1.2] MINOR — E2E loading_window_ms value assertion

**R1 finding:** TestHeartbeatSwapEmitterWritesAuditLogRow asserted
`loading_window_ms` was a JSON number but accepted 0. A pipeline
regression returning zero duration would have silently passed.

**R2 claimed fix:** Strengthened the assertion to require
`loadingWindowMs > 0` with a comment citing R-7.10.6.

**Verify:**
- Read the modified test in server_test.go around the
  `loading_window_ms` extraction. Confirm:
  - Type assertion is preserved (asserts JSON number).
  - A new check `if loadingWindowMs <= 0 { t.Fatalf(...) }` is
    present.
  - The comment cites SPEC-002 §7.10.2 R-7.10.6 and explains
    why a positive value is the meaningful regression check.
- Run the test: `go test -race -count=1 -run
  TestHeartbeatSwapEmitterWritesAuditLogRow ./internal/ws/...`.
  Confirm exit 0.

### A3 — [code:1.3] MINOR — prune cutoff-boundary test

**R1 finding:** Original `TestPruneBeforeRemovesOlderRows` used
cutoff = (now - 1d + 1s), which didn't exercise the at-cutoff row.
A future `<` → `<=` regression could be missed.

**R2 claimed fix:** Added a sibling
`TestPruneBeforeBoundaryIsStrictlyLess` that inserts rows at
cutoff-epsilon, cutoff, and cutoff+epsilon; asserts only the
strictly-before row is removed.

**Verify:**
- Read the new test in store_test.go. Confirm:
  - Rows are inserted at exactly 3 timestamps: before, at, after
    the cutoff.
  - PruneBefore is called with the exact cutoff value.
  - Assertion: `deleted == 1` (only the strictly-before row).
  - Post-prune query asserts the remaining provider_id order is
    `[at, after]` — pinning both that "at" survives AND ordering
    is preserved.
- The epsilon used in the test is 1 second (not 1µs or 1ms). The
  comment in the test explains this: SQLite's julianday() at
  float64 precision near ~2.46e6 (Julian Date magnitude for
  2026) collapses sub-millisecond differences. Verify the comment
  explains this so a future maintainer doesn't lower the epsilon.
- Confirm the original `TestPruneBeforeRemovesOlderRows` still
  passes (the boundary test is ADDITIVE, not a replacement).
- Run both: `go test -race -count=1 -run TestPruneBefore
  ./internal/audit/...`. Confirm 2 passing tests.

### A4 — [arch:1.1] MINOR — Store.DB() accessor scope documented

**R1 finding:** Exported `Store.DB()` had no comment naming its
intended scope. A future maintainer could call it from production
code and bypass the F-1.5 guard in EmitSwap.

**R2 claimed fix:** Added a doc comment naming the two legitimate
scopes (tests + future R-7.10.11 event types) and directing
production code to EmitSwap / Insert / PruneBefore.

**Verify:**
- Read the comment block above `Store.DB()` in store.go. Confirm
  it explicitly names:
  - The two legitimate scopes (test-only assertions, future
    SPEC-002 §7.10.3 R-7.10.11 event types).
  - The forbidden-in-production directive ("Production code MUST
    use EmitSwap / Insert / PruneBefore").
  - The bypass risk (F-1.5 invariant guard at R-7.10.9, plus
    eventType/providerID hygiene).
- This is a doc-only fix; no test required.

## Part B — R2 regression sniff

Look for new defects introduced by 9bfc4a8. Scoped narrowly to the
edits in this commit:

### B1 — RFC3339Nano precision and TestBuildSwapPayloadTSIsRFC3339UTC

The Fix 1 switch to RFC3339Nano produces output like
`"2026-06-07T12:00:00.000000123Z"`. The existing test uses
`time.Parse(time.RFC3339, ts)` to parse. Does RFC3339 accept the
nanosecond suffix? Yes — RFC3339Nano output is RFC3339-compliant
input. Verify by running the test (Fix 1 doesn't break it). If the
test were to use a strict `time.RFC3339` parser that rejects
fractional seconds, this would be a regression. Confirm
time.Parse(time.RFC3339, rfc3339Nano_string) succeeds in Go's
stdlib.

### B2 — Prune boundary epsilon and assertion

The R2 boundary test uses 1-second epsilon. Could this epsilon be
too LARGE such that the "before" row falls into a different day?
Cutoff is `time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC)`. Before
is `cutoff - 1s = 2026-06-07 11:59:59 UTC`. Same day. No day
boundary issue. Confirm.

### B3 — E2E loading_window_ms value assertion timing

The E2E test sets two heartbeat timestamps. Does the second
heartbeat happen >0ms after the first? Yes — `s.now()` (the
server clock) advances between handler invocations. But under
extreme test parallelism, could s.now() return identical
timestamps? Read the test harness's now() impl. If it's a
monotonic clock that increments per call, fine. If it's a
test-injected fake clock that needs explicit advancement, the
test might flake. Flag the timing assumption.

### B4 — Edit budget

The R2 commit modifies the 4 files named in the fix prompt:
store.go, store_test.go, swap_event.go, server_test.go.
Confirm via `git diff --name-only c8aba39..9bfc4a8 --
phase4-coordinator/` and verify no unintended files changed.

### B5 — Build / vet / race / suite cleanliness

The R2 bar is `go test -race -count=1 ./...` clean. Run it and
confirm exit 0.

## Output format

```
# SPEC-002 v1.3.5 Phase 2E R2 closure-verification — Codex GPT-5

## Verdict

<one-line: CLOSED-CLEAN | CLOSED-WITH-MINOR-NOTES | NOT-CLOSED |
NEW-FINDINGS>

## R1 closures

| Finding | R1 severity | R2 verdict | Test/file proof |
|---|---|---|---|
| code:1.1 (ts precision) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line + test> |
| code:1.2 (loading_window_ms value) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line + test> |
| code:1.3 (prune boundary) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <test name + file:line> |
| arch:1.1 (DB() doc comment) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line> |

## New findings introduced by R2

(zero is the expected/desired result; report whatever you find)

[r2:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>

## Build / vet / race / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/ ./cmd/
  go test -race -count=1 ./internal/audit/...
  go test -race -count=1 ./internal/ws/...
  go test -race -count=1 ./...

## Cross-cutting observations

<patterns spanning closures or new findings>
```

## Discipline

- Closure verdicts are CLOSED only when both the production fix
  AND a covering test/comment exist (except for arch:1.1 which is
  doc-only).
- New-finding severity follows the same scale as R1.
- Do not invent findings. Zero is a valid result.
- Cite file:line for every closure verdict.
- You may run `go build / vet / test / -race`. You MUST NOT
  modify any file.

You may take up to 20 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- Expected outcome: CLOSED-CLEAN, zero new findings. The R2 fixes
  are tightly scoped — 4 small fixes (~50 LOC total) addressing
  4 MINOR findings.
- If CLOSED-CLEAN, dispatch the full pre-merge audit across all 5
  phases. If new findings emerge, fix inline (R3) then proceed.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-phase-2e-r2-closure-verification-prompt-at-specs-*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).
