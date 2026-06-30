# SPEC-004 FULL IMPLEMENTATION — pre-merge audit fleet results

Per user request before merge: a holistic audit-fleet pass over the
WHOLE bundled implementation (all four pillars + per-pillar fix-
passes + CI integration fix). Five lanes fired in parallel: three
codex (CODE / SECURITY / ARCHITECT), one Claude `critic` adversarial
verifier, one Claude `critic` product critique. The user's bar is
**0 CRITICAL / HIGH / MEDIUM after R2 across all five lanes**.

Prompts live in `specs/AUDIT_SPEC_004_FULL_IMPL_*.md`; raw codex
responses + Claude subagent transcripts are under `.omc/artifacts/`
and the session task directory (gitignored).

## R1

Source commit: `34f459b` (CI integration regression fix on top of
the bundled 4-pillar IMPL).

| Lane | Tally | Top finding |
|------|-------|-------------|
| CODE codex | 0/0/2/0 | MEDIUM: server.go's local `withinRelativeEpsilon` lacked the NaN/Inf fail-closed guard `routing.WithinRelativeEpsilon` has (money-path bypass); MEDIUM: `candidate_count_before_filters` was logged as the post-filter count, `filtered_counts` always omitted (§7 log half-empty) |
| SECURITY codex | 0/1/1/0 | HIGH: live buyer sticky refresh-at-cap path still evicted unrelated entries (the fix shipped in sticky.Map.Update never reached production because of finding #1 below); MEDIUM: BalancedScores recomputed per cohort comparison |
| ARCHITECT codex | 0/0/1/1 | MEDIUM: no committed audit-result artifacts (this file fixes that); LOW: candidate.go package doc still calls D/A "wholly future" |
| Adversarial verifier (Claude critic) | 0/3/4/2 | **HIGH #1: Phase A is dead code** — sticky.Map never imported by server.go; **HIGH #2: refresh-at-cap fix doesn't reach prod**; **HIGH #3: server.go withinRelativeEpsilon lacks NaN/Inf guard** |
| Product critic (Claude critic) | 0/4/4 | DOCUMENT: Phase A framing oversells "done"; DOCUMENT: deferred-work list needs ONE tracking issue not commit-message spelunking |

**Consolidated R1 dedup:**
- Two BLOCK-MERGE HIGHs (adversarial-H1+H2+SEC-FULL-H = "Phase A dead code & refresh-at-cap"; adversarial-H3+CODE-FULL-M1 = "NaN/Inf guard bypass on hot path")
- Three actionable MEDIUMs (§7 log half-empty; AccountID overwrite on sticky refresh; PurgeAccount("") wipes empty-AccountID entries)

**Fix commit:** `cf35879` absorbed both HIGHs + 3 MEDIUMs:
- Wired server.go to `*sticky.Map` (kills dead code AND fixes refresh-at-cap regression in one move).
- Replaced inline `withinRelativeEpsilon` + `inEpsilonCohort` with delegation to `routing.InEpsilonCohort` (NaN/Inf guard now on hot path).
- Added `logRoutingDecisionFull` + `routeKeyedFilterCounts` adapter — threads `len(providers)` + `result.Counts` to the §7 log from the main selection call site.
- server.go's `purgeStickyAccount("")` early-returns 0.

## Pre-R2 follow-up fixes (commit `15f6323`)

Three remaining R1 MEDIUMs absorbed before R2:
- **adversarial-M5**: `sticky.Map.Update` now returns `mismatch bool` and refuses refresh when the existing entry's AccountID differs from the supplied one. server.go logs `sticky_account_mismatch` warn event.
- **adversarial-M7 defense-in-depth**: `sticky.Map.PurgeAccount("")` short-circuits to 0 internally (server.go guard was first line; primitive guard is defense-in-depth).
- **ARCH-FULL-M1**: this file + per-pillar audit-result artifact files written.

## R2

Source commit: `15f6323` (pre-R2 fix-pass). 5 lanes fired in parallel.

| Lane | Tally | Notes |
|------|-------|-------|
| CODE codex | 0/0/1/1 | MEDIUM: empty incoming AccountID on Update refresh erased existing non-empty AccountID (sticky.go:139 guard caught both-non-empty mismatch but not asymmetric-empty case); LOW: candidate.go package doc still labeled D/A "wholly future" |
| SECURITY codex | **0/0/0/0 ACCEPT** ✅ | — |
| ARCHITECT codex | **0/0/0/0 ACCEPT** ✅ | explicit "no architect-blocking R2 findings"; deferred items confirmed genuinely deferrable under R2 lens |
| Adversarial verifier | 0/0/0/2 | confirmed R1-HIGH-1/2/3 + R1-MEDIUM-M5/M7 all genuinely fixed; 2 LOWs (no test for sticky_account_mismatch log; no rate-limit on warn) |
| Product critic | 0/1/2/2 | **HIGH**: PR body still claimed sticky.Map "is not yet the production storage" (was true pre-fix, false now); MEDIUM: this file shipped with `<next commit>` placeholder + 5 "TBD" rows; MEDIUM: PILLAR_DA "Lesson logged (memory rule TBD)" wikilink unresolved |

**Pre-R3 fix-pass (commit `TBD`)** absorbed all C/H/M from R2:
- CODE-R2-M1: `Update` now also preserves `existing.AccountID` when incoming is empty (was the asymmetric edge case). New regression test `TestMap_UpdatePreservesExistingAccountIDWhenIncomingIsEmpty`.
- Product-R2-H1: PR body refreshed — removed the stale "sticky-package wiring deferred" claim, added FULL-IMPL audit fleet section to the convergence table.
- Product-R2-M1: this file's `<next commit>` substituted with `15f6323`; R2 tally rows populated (above).
- Product-R2-M2: PILLAR_DA `(memory rule TBD)` line resolved (memory rule written or inlined).
- LOW cleanups: candidate.go package doc updated to reflect landed D/A work + remaining deferred list.

## R3

Source commit: TBD (next push after the R2 fix-pass above).

| Lane | Tally | Notes |
|------|-------|-------|
| CODE codex | TBD | — |
| SECURITY codex | sustained ACCEPT (likely skipped per accepted-lane rule unless R2 fix-pass touches a security boundary) | — |
| ARCHITECT codex | sustained ACCEPT (likely skipped) | — |
| Adversarial verifier | TBD | — |
| Product critic | TBD | — |
