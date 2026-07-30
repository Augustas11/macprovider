# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 10

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**READY WITH LOW HYGIENE CLEANUP:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 3 LOW, 3 INFO.

The v10 fix pass closed the CODE r9 blockers. The auth-failure limiter is now scoped to Authorization-present failures with a reserve/refund pattern, the nginx split-location alternative is mechanically valid, and the Shape C rebuild tests are now Shape-C-specific. I found no remaining code-mechanics issue that should cause a conforming implementer to write runtime-broken code, fail a locked AC test, or diverge on package/grant ownership. The remaining issues are stale reference/count wording.

## Findings

### CODE-R10-001 - LOW - Two stale AC-21/21-AC references remain after AC-22 was added

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:671`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:726`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:2229-2341`

**Finding:** The prompt elsewhere correctly anchors to v0.1.8 and AC-22, including the Step 3 AC-22 tests, the §2.4 AC matrix, and the final "all 22 ACs" done criteria. Two prose lines still say staging keys are for "AC-1..AC-21" fixture work and that the SPEC has "21 ACs."

**Risk:** Low. The binding matrix and final smoke list include AC-22, so an implementer has enough correct direction. The stale count is still confusing in a fresh kickoff prompt and can cause audit churn.

**Fix:** Change both references to `AC-1..AC-22` / `22 ACs`, or avoid hardcoding the count.

### CODE-R10-002 - LOW - Stale Shape A/B and burst wording remains in non-binding summary prose

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:44`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:626`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1111-1121`, `specs/SPEC-017-network-stats-api.md:2085-2148`

**Finding:** The v0.1.7 delta summary still says §9.4 pins "Shape A temp-table swap OR Shape B atomic table rename." A deploy-gate line says "fail-closed burst," and a Step 4.B test bullet says "Burst behavior." The prompt's binding v0.1.8 sections correctly require Shape C by default and no `burst=` in nginx, so this is not a functional contradiction.

**Risk:** Low. Nearby mandatory text prevents an implementer from choosing Shape A/B under locked grants or configuring burst. The stale terms are grep-level confusion in an implementation kickoff prompt.

**Fix:** Reword to "single PostgreSQL transaction; v0.1.8 Shape C is the default" and "no-burst hard-limit behavior."

### CODE-R10-003 - LOW - Required-reading pointer sends implementers to the wrong SPEC-006 section for header allowlists

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:732`  
**Dependency evidence:** `specs/SPEC-006-buyer-api.md:1065-1095`, `specs/SPEC-006-buyer-api.md:1729-1753`, `specs/SPEC-006-buyer-api.md:2505-2608`

**Finding:** The required-reading list says to read `SPEC-006-buyer-api.md` "§17 (header strip / X-MacProvider-* allowlist)." In current SPEC-006 v0.9, §17 is failure modes. The header stripping and response-pass-through allowlists live under §5.4 and §8.3.

**Risk:** Low. `X-Stats-Generated-At` does not collide with the `X-MacProvider-*` namespace, and the SPEC-017 prompt already pins the stats header directly. This is still a wrong section pointer in the kickoff checklist.

**Fix:** Point the dependency reading item at SPEC-006 §5.4 and §8.3 instead of §17.

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.8 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.1-§7.6, §8, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-22.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package with `store` and `rollup` subpackages remains consistent with the existing explorer pattern while keeping the public stats surface out of explorer.
- Checked prior ARCH r8, CODE r9, and SECURITY r6 audit continuity. The CODE r9 HIGH/MEDIUM issues are absorbed in the current prompt.
- Verified dependency line-3 versions: SPEC-002 v1.4, SPEC-005 v0.3, SPEC-006 v0.9, SPEC-014 v0.8, SPEC-016 v0.1.19.
- Verified SPEC-005 ledger denial targets exist: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
- Verified all prompt AC references are AC-1 through AC-22 and each maps to current §10 content, aside from the two stale prose count references above.
- Verified Postgres grant shapes named in the prompt are syntactically valid PostgreSQL: table grants use valid privilege kinds, backing sequences use `GRANT USAGE, SELECT ON SEQUENCE`, and the optional `partner_keys_writer` is correctly default-off because the locked column-scoped UPDATE grant cannot support the natural `WHERE id = $2` worker query.

## Category Walk

- **A. Section number drift:** PASS with LOW hygiene. SPEC-017 citations resolve under v0.1.8. Dependency pointer to SPEC-006 §17 is stale.
- **B. Postgres grant shape correctness:** PASS. Table names and sequence grants match the locked schemas; no role/pool sharing is permitted.
- **C. Go package boundary correctness:** PASS. `internal/stats`, `internal/stats/store`, and `internal/stats/rollup` boundaries match §7.6 and the existing flat explorer handler pattern.
- **D. Wire-contract correctness:** PASS with LOW hygiene. Token length math, 204-only CORS preflight, closed error vocabulary, status codes, cache directives, Vary rules, `X-Stats-Generated-At`, and AC-22 auth-failure semantics are aligned.
- **E. AC test-coverage mapping:** PASS with LOW hygiene. AC-1 through AC-22 have owners and concrete test shapes; two prose references still say 21.
- **F. Migration / IMPL-time decision drift:** PASS. Dependency re-checks, hostname posture, and both backfill paths are gated correctly.
- **G. Test-shape correctness:** PASS. Step 2 Shape C, Step 3 handler/auth/CORS, and Step 4 nginx/CLI/observability tests are mechanically writable.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB` pools, typed request context for bearer transfer, recover middleware, and default-off `last_used_at` worker posture are pinned.
- **I. Naming hygiene:** MIXED LOW. Role names, table names, CLI names, and event names are consistent; stale "burst" and "21 ACs" wording remains.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 10 is code-mechanics ready, with only low hygiene cleanup left. The current IMPL prompt is anchored to locked SPEC-017 v0.1.8 and carries the important repair work from the prior ARCH/CODE/SECURITY passes: Shape C is the v0.1 rebuild default, burst is removed, AC-22 is present and owned by Step 3, Authorization-aware nginx keying has concrete valid shapes, and the auth-failure limiter is now scoped as a reserve/refund failed-bearer guard instead of a blanket 300 rpm cap on valid partner traffic.

I did not find any remaining prompt defect that should make an implementer write wrong grants, wrong table names, wrong package boundaries, wrong token generation, wrong CORS/status/cache behavior, or an AC-missing test plan. Postgres grant syntax checks out, including sequence grants and the default-off `partner_keys_writer` decision. The `internal/stats` package layout matches the existing `internal/explorer` flat handler pattern while preserving the stricter stats import boundary.

The remaining cleanup is reference hygiene: two lines still say 21 ACs after AC-22, a few stale "Shape A/B" and "burst" terms remain in non-binding prose, and the SPEC-006 reading pointer should target §5.4/§8.3 rather than §17. They are cleanup edits, not implementation blockers for the v0.1.8 kickoff at this point. No fix prompt was drafted.
