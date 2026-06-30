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

## Pre-R2 follow-up fixes (`<next commit>`)

Three remaining R1 MEDIUMs absorbed before R2:
- **adversarial-M5**: `sticky.Map.Update` now returns `mismatch bool` and refuses refresh when the existing entry's AccountID differs from the supplied one. server.go logs `sticky_account_mismatch` warn event.
- **adversarial-M7 defense-in-depth**: `sticky.Map.PurgeAccount("")` short-circuits to 0 internally (server.go guard was first line; primitive guard is defense-in-depth).
- **ARCH-FULL-M1**: this file + per-pillar audit-result artifact files written.

## R2

Source commit: TBD (next push). Fires 5 lanes again:
- CODE codex
- SECURITY codex
- ARCHITECT codex
- Adversarial verifier (Claude critic)
- Product critic (Claude critic)

Goal per user rule: **0 CRITICAL / HIGH / MEDIUM across every lane**.

| Lane | Tally | Notes |
|------|-------|-------|
| CODE codex | TBD | — |
| SECURITY codex | TBD | — |
| ARCHITECT codex | TBD | — |
| Adversarial | TBD | — |
| Product critic | TBD | — |
