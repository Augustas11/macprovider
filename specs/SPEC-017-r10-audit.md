# SPEC-017 v0.1.8 audit report — Round 10 (Codex, 2026-06-26T05:19:51Z)

## Summary

- 0 CRITICAL findings
- 0 MAJOR findings
- 0 MINOR findings
- 0 QUESTIONS

## CRITICAL findings

None.

## MAJOR findings

None.

## MINOR findings

None.

## Operator questions surfaced

None beyond the open questions already listed in SPEC-017 §11.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** No findings. SPEC-017 covers endpoint wire shape (§5), rollup tables/cadence (§9), auth/key/rate/CORS (§5.4-§5.7), earnings visibility (§6), hosting/isolation (§7), and version/deprecation (§8). The required deferrals remain explicit in §1.3 and §11.
- **Category B — Endpoint contract correctness:** No findings. Overview has 14 `network.*` fields (§5.1.1), timeseries null-vs-zero semantics are pinned (§5.1), leaderboard validation rejects invalid `window`/`sort`/`limit` rather than clamping (§5.2), public/partner projection is additive (§5.2), health returns 200 for degraded components (§5.3), and §5.9 governs non-2xx envelopes including stale-503 and 429 cases.
- **Category C — Earnings visibility model:** No findings. Bucketed default and left-join default behavior are explicit (§6.1), bucket thresholds are combined work-plus-rewards buckets with exact per-axis fields nullable in public projection (§6.2), the SPEC-014 v0.9 UI handoff is clean (§6.3), same-origin uniformity is stated (§6.4), audit rows cover provider and operator actors (§6.5), and legal disclosure plus operator override direction are coherent (§6.6).
- **Category D — Hosting and isolation:** No findings. `/v1/stats/*` does not collide with SPEC-002 paths, the hostname pattern is not a v0.1 lock gate (§7.1), grants align with §9.1/§9.1a table ownership and Shape C refresh semantics (§7.2, §9.4), separate `*sql.DB` use is a MUST (§7.2.5), recover middleware is scoped to the stats subtree (§7.3), nginx pins behavior rather than version (§7.4), and import-graph isolation is mechanically checkable (§7.6, AC-16).
- **Category E — Versioning and deprecation:** No findings. `/v1` path versioning is the sole version surface (§8.1), additive and breaking change rules are internally consistent (§8.2-§8.3), the `Deprecation`, `Sunset`, and `Link: rel="deprecation"` header examples are coherent (§8.4), and the public changelog path is a future implementation artifact rather than a lock precondition (§8.5).
- **Category F — Rollup pipeline:** No findings. Cadences align with freshness budgets (§9.2, §9.5), late-event correction distinguishes 24h/7d full recompute from 30d/all incremental plus rebuild (§9.3), the 48h lookback and 0.5% drift threshold are justified in-spec (§9.3-§9.4), failure modes define stale serving/log/metric/retry/recover behavior (§9.6), and `partial_history_since` has a schema home plus emission rules (§5.2, §9.7).
- **Category G — Acceptance criteria quality:** No findings. AC-1 through AC-22 are contiguous and mechanically cover the three endpoints, partner-key flow, bucketed-vs-exact rendering, audit table, rate limits including the v0.1.8 auth-failure tier, CORS/OPTIONS, role isolation, panic recover, ETag, stale-503, log redaction, and import-graph lint.
- **Category H — Cross-spec invariant preservation:** No findings. SPEC-002 mount and path tree are preserved; SPEC-005 work-dollar math is referenced rather than redefined; SPEC-006 `X-MacProvider-*` header namespace is not extended or collided with; SPEC-017 owns its local error envelope explicitly; SPEC-014 v0.8 has a plausible authenticated portal home for the future toggle without making v0.9 a SPEC-017 lock dependency; SPEC-016 remains v0.1.19 in this worktree and rewards semantics are explicitly deferred to an operator-defined ledger.
- **Category I — Honesty about deferrals:** No findings. §11 questions are genuine v0.2+ decisions rather than hidden pinned choices; §1.3 names out-of-scope surfaces; and the current `frontdoor/console/index.html` buyer-side dashboard is correctly not treated as the canonical Network Stats UI consumer per §1.4 and Q12.
- **Category J — Spec hygiene:** No findings. Version-of-record and dependency versions match the repo line-3 versions; the change log keeps audit narrative out of the SPEC body; no literal `TBD` appears; RFC-2119 usage is acceptable; and the locked-decision citation has a canonical in-repo mirror at `specs/SPEC-017-advisor-round-2026-06-25.md`.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.8 (§§1-12, ACs 1-22).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. No drift found.
- [x] Walked each Category A through J. Each category is noted above with "no findings."
- [x] Severity was evaluated against the prompt definitions; no items met CRITICAL, MAJOR, MINOR, or QUESTION thresholds.
- [x] Location requirement is not applicable to empty finding buckets; category evidence above cites the relevant sections.
- [x] No CRITICAL findings exist, so no CRITICAL suggested fixes are required.
- [x] Checked dependency line-3 versions for SPEC-002, SPEC-005, SPEC-006, SPEC-014, and SPEC-016 against SPEC-017's `Depends on:` line.
- [x] Checked the requested advisor source path under `.omc/artifacts/ask/`; the exact source file name is absent in this worktree, so the canonical in-repo mirror cited by SPEC-017 §12 was read instead.

## Verdict

- READY TO LOCK

Round 10 found no CRITICAL, MAJOR, MINOR, or new operator-question issues. The v0.1.8 changes close r9's rate-limit contradictions without reopening the locked architecture, privacy, or isolation decisions.
