# Issue #266 Tranche 2 — audit results

Three-lane codex audit on PR for issue #266 Tranche 2 (refactor-only extractions: objective.go / dispatch.go / retry.go).

## R1 — 2026-06-30

Commit audited: `1084c71` (initial extractions) + `2943f99` (audit prompts).

| Lane | C | H | M | L | Status |
|------|---|---|---|---|--------|
| CODE | 0 | 0 | 0 | 0 | ✅ ACCEPT |
| SECURITY | 0 | 0 | 0 | 1 | ✅ ACCEPT |
| ARCHITECT | 0 | 0 | 0 | 10 | ✅ ACCEPT |

**All three lanes at C/H/M = 0. Merge bar met on R1.**

### R1 findings — fixed

**SEC-L1** (RewriteModel precondition undocumented on match-skip path): match-skip path skips dup/case/non-object validation; pre-extraction `buyer.dispatchBodyForProvider` had the same behaviour but the new exported routing-package surface deserves explicit documentation. Fixed: added a `**Precondition**` block to RewriteModel's docstring stating callers outside the buyer pipeline must run JSON-shape validation themselves.

**ARCH-L10** (stale package doc on candidate.go): `routing` package comment listed objective.go / dispatch.go / retry.go as deferred — they now ship in this PR. Fixed: rewrote the package doc to mark T1 (PR #270) and T2 (this PR) as closed and describe what remains for T3.

### R1 findings — accepted with rationale (no code change)

**ARCH-L1** (providerSortKey vs routeKey duplication): the right fix is `pool.Provider.SortKey()` method on the pool type. Cross-package refactor; deferred to a follow-up that owns the pool API change.

**ARCH-L2** (SortCandidates + ObjectiveScores recompute BalancedScores for balanced): aligns with the deferred #266 T3 "BalancedScores compute caching" item. T3 will thread a reusable score cache through sort + epsilon + log.

**ARCH-L3** (ShouldRetryInput struct vs positional args): the struct names every policy input and supports clean unit testing. Accepted.

**ARCH-L4** (buyer.Server.shouldRetry wrapper stays): centralises server-state bundling in one place; inlining at all four call sites would duplicate the bundling for no architecture win. Accepted.

**ARCH-L5** (RewriteModel returns copied []byte in both paths): conservative copy semantics; the WS / HTTP / streaming dispatch all build readers from the returned body, never mutate in place. Adding a "do not mutate" alias contract would be fragile. Accepted.

**ARCH-L6** (config→routing import-cycle constraint): new routing files don't import internal/config; routing imports pool, pool imports config. Constraint is unchanged from pre-T2 state. Accepted.

**ARCH-L7** (coverage net-additive vs redundant): routing tests pin the new pure boundary; buyer tests still cover integration paths and transport behaviour. Both layers stay. Accepted.

**ARCH-L8** (KeyedBalancedScores cache target, but SortCandidates has no cache-threading API yet): T3 will introduce SortAndScore or thread a score cache through sort/epsilon/log. Accepted for T2.

**ARCH-L9** (RetryHeaderLimit fmt.Sscanf accepts `3abc` as `3`): pre-existing behaviour, not a T2 regression. Follow-up could switch to `strconv.Atoi(strings.TrimSpace(value))` + test for `3abc → 0`. Tracked as a future cleanup; not gating T2 since behaviour is byte-identical to `798e57b`.

## Convergence

R1 absorbed 0 CRITICAL / 0 HIGH / 0 MEDIUM and acknowledged 11 LOWs (2 fixed, 9 accepted with rationale). All three lanes locked at C/H/M = 0 on the first round. The "refactor-only" goal was met cleanly.

Per [[feedback-skip-accepted-audit-lanes]], no R2 is needed: the fix-pass touches only documentation comments (`dispatch.go` docstring + `candidate.go` package doc), no code semantics. All three lanes would sustain ACCEPT.

Ready for PR + merge.
