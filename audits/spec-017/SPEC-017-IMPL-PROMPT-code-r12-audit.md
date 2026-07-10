# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 12

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 0 CRITICAL, 1 HIGH, 0 MEDIUM, 3 LOW, 0 INFO.

The r12 prompt has absorbed the r11 blockers: `stats_rollup_state` is gone, `partial_history_since` is config-backed, and rate-limit examples now carry the endpoint dimension in both in-process and nginx shapes. The remaining code-mechanics issue is narrower: one CORS paragraph names the wrong §5.7 rows and can make an implementer/test author apply partner-key `ACAO != *` rules to the public leaderboard row, which the locked SPEC says must emit `*`. The other findings are stale reference hygiene.

## Findings

### CODE-R12-001 - HIGH - CORS row-number drift can forbid `ACAO: *` on the public leaderboard row

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:385-390`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:496`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1183-1191`, `specs/SPEC-017-network-stats-api.md:1193-1200`

**Finding:** The prompt correctly states that partner-key projection responses must never emit `Access-Control-Allow-Origin: *`, but then says this applies to "rows 2/3/4 of the v0.1.7 §5.7 table." In the locked SPEC, §5.7 row 2 is `/leaderboard` public with no key and **must** emit `Access-Control-Allow-Origin: *`. The partner-key 200 projection rows are rows 3, 4, and 5: empty-allowlist browser context, empty-allowlist server-to-server context, and non-empty allowlist matched Origin. The later test bullet uses rows 3/4/5, so the prompt is internally inconsistent.

**Risk:** High. A conforming implementation or audit test following the wrong parenthetical could reject `ACAO: *` on the anonymous public leaderboard response, violating locked SPEC §5.7 row 2. That code would compile and serve but fail a CORS contract test once the row-2 assertion is written.

**Fix:** Replace the row set at line 390 with "rows 3/4/5 of the §5.7 table" or avoid row numbers entirely: "any successful partner-key projection response." Keep public `/leaderboard` row 2 explicitly allowed to emit `ACAO: *`.

### CODE-R12-002 - LOW - Rollup OLTP source-grant recheck points to the wrong prereq

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:164`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1609-1618`, `specs/SPEC-017-network-stats-api.md:1648-1651`

**Finding:** The prompt tells the implementer to re-verify the locked SPEC-002 + SPEC-005 OLTP source grants at IMPL time "per §1 prereq 3." But §1 prereq 3 in the IMPL prompt is the SPEC-016 rewards-source dependency check, not the SPEC-002/SPEC-005 source-table inventory check. The prompt does still say to re-verify the dependency line-3 versions and the required-reading list points at SPEC-002/SPEC-005, so the executable instruction is present; only the cross-reference is wrong.

**Risk:** Low. This is citation hygiene, not an immediate grant-shape bug. The local sentence already names the relevant SPEC-002/SPEC-005 tables and says to re-verify them at IMPL time.

**Fix:** Change the cross-reference to the required-reading bullets for SPEC-002/SPEC-005, or add a distinct §1 pre-kickoff item for "Pin SPEC-002/SPEC-005 source-table inventory at IMPL time."

### CODE-R12-003 - LOW - Two stale `AC-1..AC-21` / `21 ACs` references remain after AC-22

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:689`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:744`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:2229-2341`

**Finding:** The prompt's binding matrix and final checklist correctly include AC-22, but the Step 4.C staging-key sentence still says `AC-1..AC-21`, and the required-reading list says "21 ACs." The locked SPEC now has AC-1 through AC-22.

**Risk:** Low. The authoritative AC-to-step matrix and final done criteria say all 22 ACs, so this should not drop coverage, but stale counts cause audit churn.

**Fix:** Replace both with `AC-1..AC-22` / `22 ACs`, or avoid hardcoded counts.

### CODE-R12-004 - LOW - Stale "burst" wording remains after the no-burst v0.1.8 reconciliation

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:644`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1111-1121`

**Finding:** The prompt's binding nginx section correctly forbids `burst=` and requires `limit_req ... nodelay`, but a cutover-prereq line still says "fail-closed burst" and the Step 4.B test list still labels a test "Burst behavior." v0.1.8 removed burst from the rate-limit model entirely.

**Risk:** Low. Nearby normative text prevents a conforming implementer from adding `burst=`, but the stale word is misleading in a fresh kickoff prompt.

**Fix:** Reword to "fail-closed hard-limit behavior" and "No-burst threshold behavior."

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.8 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.1-§7.6, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-22.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package, separate `store` DAO, and `rollup` subpackage do not fight the existing explorer handler pattern.
- Walked prompt SPEC-017 section citations used for implementation mechanics. The only actionable drift found is the CORS row-number drift; stale dependency cross-reference is LOW hygiene.
- Walked AC references against §10. AC-1 through AC-22 are mapped in §2.4; stale prose still says 21 in two places.
- Walked role and grant inventory. Prompt now matches locked §7.2 for required roles, keeps `partner_keys_writer` default-off, and uses a separate operator DSN for CLI writes.
- Walked table names against §9.1 / §9.1a / §6.1 / §6.5 / §5.4.1. No prompt-only runtime table remains.
- Checked package boundaries against §4.2 / §7.6 and the explorer import pattern.

## Category Walk

- **A. Section number drift:** FAIL HIGH for §5.7 CORS row-number drift; otherwise SPEC-017 citations resolve.
- **B. Postgres grant shape correctness:** PASS. Required roles, sequence grants, explicit denies, optional `partner_keys_writer`, and separate CLI operator DSN are mechanically aligned.
- **C. Go package boundary correctness:** PASS. Request-path stats packages are isolated; rollup carve-out is read-only and excludes explorer/ws/auth except minimal bearer parsing.
- **D. Wire-contract correctness:** FAIL HIGH for the CORS row parenthetical. Partner-key token math, 204 preflight, error code vocabulary, statuses, cache directives, ETag/304, and `X-Stats-Generated-At` are otherwise aligned.
- **E. AC test-coverage mapping:** PASS with LOW hygiene. AC-1 through AC-22 have owners; two stale prose references still say 21.
- **F. Migration / IMPL-time decision drift:** PASS with LOW hygiene. Backfill and hostname choices are gated correctly; SPEC-002/SPEC-005 source-grant recheck has a wrong local prereq cross-reference.
- **G. Test-shape correctness:** PASS. Fixture corpus, Shape C atomicity, nginx per-endpoint rate-limit tests, AC-18 statistical timing, AC-20 CI SQL assertion, and AC-22 auth-failure tests are mechanically writable.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB`, typed context bearer transfer, recover middleware shape, and default-off `last_used_at` worker posture are pinned.
- **I. Naming hygiene:** MIXED LOW. Role/table/event names are consistent; stale "burst" and "21 ACs" wording remains.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 12 is close, but not code-mechanics ready. The previous blockers are fixed: the prompt no longer adds a prompt-only `stats_rollup_state` table or grants, and the rate-limit instructions now carry the required per-endpoint dimension for both in-process buckets and nginx zones. Role isolation, package layout, Shape C rebuild, partner-key token format, preflight 204, closed error vocabulary, ETag/304, cache directives, AC-22, and the AC ownership matrix are aligned with locked SPEC-017 v0.1.8.

One HIGH remains. The CORS section correctly says partner-key projection responses must never emit `Access-Control-Allow-Origin: *`, but it names rows 2/3/4 of §5.7. In the locked SPEC, row 2 is anonymous public `/leaderboard` and must emit `*`; successful partner-key projection rows are 3/4/5. That wrong row reference could make an implementer or test author forbid `ACAO: *` on the public leaderboard response, failing §5.7.

The other issues are low hygiene: the SPEC-002/SPEC-005 source-grant recheck points at the wrong prereq, two stale "21 ACs" references remain after AC-22, and two stale "burst" labels remain despite v0.1.8's no-burst rate-limit model. I did not find remaining prompt-only table additions, wrong package boundaries, broken partner-key length math, invalid grant syntax, or missing AC owners. No fix prompt was drafted.
