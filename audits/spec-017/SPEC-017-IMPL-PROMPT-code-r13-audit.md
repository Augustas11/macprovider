# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 13

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**READY FOR CODE-MECHANICS CONVERGENCE:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 3 LOW, 0 INFO.

The r12 HIGH is fixed. The current prompt names the locked §5.7 partner-key projection rows as rows 3/4/5 and explicitly preserves public `/leaderboard` row 2 as `Access-Control-Allow-Origin: *`. I did not find a remaining prompt defect that would make an implementer ship runtime-broken code or fail a locked AC test. The remaining issues are stale reference hygiene only.

## Findings

### CODE-R13-001 - LOW - Rollup OLTP source-grant recheck still points to the wrong local prereq

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:164`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1609-1618`, `specs/SPEC-017-network-stats-api.md:1648-1651`

**Finding:** The prompt correctly says the `stats_rollup` OLTP source-table SELECT grants must be enumerated at IMPL time against locked SPEC-002/SPEC-005 line-3 versions, but it closes the sentence with "per §1 prereq 3." In the IMPL prompt, §1 prereq 3 is the SPEC-016 rewards-source dependency check, not the SPEC-002/SPEC-005 OLTP source-table grant inventory.

**Risk:** Low. The same sentence names the intended SPEC-002/SPEC-005 source tables, and the required-reading list points at those dependency specs. This is a bad cross-reference, not an executable grant-shape error.

**Fix:** Replace the local cross-reference with the SPEC-002/SPEC-005 required-reading bullets, or add a separate §1 pre-kickoff item for "Pin SPEC-002/SPEC-005 source-table inventory at IMPL time."

### CODE-R13-002 - LOW - Stale `AC-1..AC-21` / `21 ACs` wording remains after AC-22

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:689`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:744`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:2229-2341`

**Finding:** The authoritative AC matrix and final checklist correctly include AC-22, but two prose references still say `AC-1..AC-21` / "21 ACs." Locked SPEC-017 v0.1.8 has AC-1 through AC-22.

**Risk:** Low. The single-source AC matrix maps AC-22 to Step 3 and the end-of-implementation checklist requires all 22 ACs, so this should not drop coverage.

**Fix:** Replace with `AC-1..AC-22` / `22 ACs`, or avoid hardcoded AC counts.

### CODE-R13-003 - LOW - Stale "burst" labels remain in no-burst v0.1.8 prompt text

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:644`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1103-1121`

**Finding:** The binding nginx section correctly forbids `burst=` and requires `limit_req zone=<name> nodelay;`, but a cutover-prereq bullet still says "fail-closed burst" and a Step 4.B test is titled "Burst behavior." v0.1.8 removed burst from both public and partner tiers.

**Risk:** Low. Nearby normative text prevents an implementer from adding an nginx `burst=` parameter, but the labels are misleading in a fresh kickoff prompt.

**Fix:** Reword to "fail-closed hard-limit behavior" and "No-burst threshold behavior."

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully, including the Step 1 grant inventory, Step 3 handler/CORS/rate-limit directives, Step 4 nginx/CLI directives, and §2.4 AC matrix.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.8 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.1-§7.6, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-22.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package, separate `store` DAO, and `rollup` subpackage do not fight the existing explorer handler pattern.
- Checked the r12 HIGH directly: prompt line 390 now names §5.7 rows 3/4/5 for partner-key projection `ACAO != *` and explicitly says public row 2 still emits `ACAO: *`.
- Walked prompt AC references against SPEC §10. AC-1 through AC-22 all have owners in §2.4; stale prose count is LOW only.
- Walked role and grant inventory. Required roles, sequence grants, optional/default-off `partner_keys_writer`, and separate CLI operator DSN are mechanically aligned with §7.2 and §5.4.1.
- Checked package boundaries against §4.2 / §7.6 and the existing explorer import/event pattern.

## Category Walk

- **A. Section number drift:** PASS for blocking mechanics. Only LOW local prereq cross-reference remains.
- **B. Postgres grant shape correctness:** PASS. Grant kinds, table names, sequence grants, and role separation are mechanically valid.
- **C. Go package boundary correctness:** PASS. Request-path packages stay isolated; rollup read-only carve-out is explicit.
- **D. Wire-contract correctness:** PASS. Partner-key math, 204 preflight, error vocabulary, status codes, cache directives, CORS row mapping, ETag/304, and `X-Stats-Generated-At` are aligned.
- **E. AC test-coverage mapping:** PASS with LOW hygiene. AC-1 through AC-22 have owners and test shapes.
- **F. Migration / IMPL-time decision drift:** PASS with LOW hygiene. Backfill and hostname modes are implemented/config-selected; source grants are rechecked at IMPL time.
- **G. Test-shape correctness:** PASS. Fixture corpus, Shape C atomicity, nginx per-endpoint tests, AC-18 statistical timing, AC-20 CI SQL assertion, and AC-22 auth-failure tests are mechanically writable.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB`, typed context bearer handling, recover middleware shape, and default-off `last_used_at` worker posture are pinned.
- **I. Naming hygiene:** MIXED LOW. Role/table/event names are consistent; stale AC-count and burst labels remain.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 13 is code-mechanics ready. The v14 narrow CORS fix resolved the only r12 HIGH: the prompt now says partner-key projection rows 3/4/5 of locked §5.7 must never use `Access-Control-Allow-Origin: *`, and it explicitly reminds implementers that public `/leaderboard` row 2 still emits `*`. That removes the risk of accidentally forbidding the anonymous public CORS contract.

I did not find any remaining critical, high, or medium code-mechanics defects. The prompt aligns with SPEC-017 v0.1.8 on partner-key token format, preflight 204, closed error vocabulary, 405 envelope plus `Allow`, weak ETag/304 semantics, cache directives, `X-Stats-Generated-At`, auth-failure tier, nginx Authorization-aware keying, Shape C rebuild, package boundaries, DB role separation, sequence grants, and AC-1 through AC-22 ownership.

Three LOW hygiene items remain: the SPEC-002/SPEC-005 OLTP source-grant recheck points at the SPEC-016 prereq by mistake; two stale prose references still say `AC-1..AC-21` / "21 ACs" after AC-22; and two stale "burst" labels remain even though the binding rate-limit text forbids burst. These do not block convergence because the authoritative implementation directives and matrix are correct. No fix prompt was drafted.

I treated the current SPEC file's v0.1.8 header as controlling despite older audit-routing text that mentions v0.1.6, because the locked file has advanced.
