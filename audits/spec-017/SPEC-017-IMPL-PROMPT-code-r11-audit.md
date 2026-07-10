# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 11

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 0 CRITICAL, 2 HIGH, 0 MEDIUM, 3 LOW, 0 INFO.

The prompt is mostly re-anchored to v0.1.8 and correctly carries Shape C, AC-22, the SPEC-014 surface split, and the `501` -> `601` partner-rate correction. However, the v11 `stats_rollup_state` addition crosses the locked SPEC boundary: the table is not in SPEC §9.1 / §9.1a / §6.1 / §6.5 / §5.4.1, and the grants are not in SPEC §7.2. A conforming implementer following the prompt would add non-SPEC runtime tables/grants. Separately, the rate-limit implementation guidance still omits the endpoint dimension in concrete in-process and nginx keying examples, despite SPEC §5.6 requiring per-endpoint buckets.

## Findings

### CODE-R11-001 - HIGH - `stats_rollup_state` table and grants are not in the locked SPEC grant/table inventory

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:144`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:155`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:167`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:170`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:323`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:351`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:508`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1560`, `specs/SPEC-017-network-stats-api.md:1574`, `specs/SPEC-017-network-stats-api.md:1626`, `specs/SPEC-017-network-stats-api.md:1654`, `specs/SPEC-017-network-stats-api.md:1840`, `specs/SPEC-017-network-stats-api.md:2187`

**Finding:** The prompt now mandates a new `stats_rollup_state` table, preseeded rows, `stats_reader` SELECT, and `stats_rollup` SELECT/INSERT/UPDATE/DELETE. The locked SPEC's §7.2 grant inventory enumerates the tables each role may access; `stats_reader` does not list `stats_rollup_state`, `stats_rollup` does not list it, and §7.2.2 explicitly says non-OLTP additional grants on `stats_rollup` are a contract violation. SPEC §9.1 and §9.1a also do not define this table. §9.7 requires `partial_history_since` behavior, but it does not authorize a new stats table/grant shape.

**Risk:** High. The SPEC is locked; this prompt would cause the IMPL author to ship migrations and runtime role grants that violate the controlling contract. That is not just implementation detail because the prompt changes the DB role surface under §7.2. A schema/grant audit written from the locked SPEC would fail.

**Fix:** Remove `stats_rollup_state` from the IMPL prompt unless the SPEC is bumped to define it and its grants. If no SPEC bump is allowed, direct the implementation to derive `partial_history_since` from already-authorized config/runtime state, or keep the storage choice entirely outside the locked role inventory without adding new role grants.

### CODE-R11-002 - HIGH - Concrete rate-limit keying omits the endpoint dimension required by §5.6

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:446`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:580`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:586`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:595`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:601`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1105`, `specs/SPEC-017-network-stats-api.md:1107`, `specs/SPEC-017-network-stats-api.md:1108`, `specs/SPEC-017-network-stats-api.md:1109`, `specs/SPEC-017-network-stats-api.md:1132`

**Finding:** SPEC §5.6 defines public, partner, and auth-failure limits as per endpoint. The prompt's post-auth success middleware says the buckets key on client IP or `partner_keys.id`, omitting endpoint. The nginx examples also define a single `stats_public` zone keyed only by `$binary_remote_addr` / `$public_rl_key`; unless the author independently creates one zone per endpoint or includes the endpoint in the key, `/overview`, `/leaderboard`, and `/health` share one quota.

**Risk:** High. The code would compile and the narrow AC-8 single-endpoint test would pass, but a §5.6 per-endpoint test would fail: 60 `/overview` requests would exhaust quota for `/leaderboard`, and partner requests to different endpoints could share one 600 rpm bucket.

**Fix:** Pin bucket keys as `(tier subject, endpoint)`: public fallback `(client_ip, endpoint)`, partner `(partner_keys.id, endpoint)`, auth-failure `(client_ip, endpoint)`. For nginx, either define separate zones per endpoint or include a stable endpoint token in the mapped key; update Step 4.B tests to prove one endpoint's quota does not debit another's.

### CODE-R11-003 - LOW - Two stale AC-21 / 21-AC references remain after AC-22

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:687`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:742`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:2229`, `specs/SPEC-017-network-stats-api.md:2335`

**Finding:** The prompt correctly owns AC-22 in the Step 3 tests and §2.4 matrix, but two prose lines still say staging fixture work covers `AC-1..AC-21` and that the SPEC has `21 ACs`.

**Risk:** Low. The binding matrix and final smoke list say all 22 ACs. This is stale kickoff wording that can cause audit churn.

**Fix:** Change both references to `AC-1..AC-22` / `22 ACs`, or avoid hardcoded counts.

### CODE-R11-004 - LOW - Stale Shape A/B and burst wording remains in summary prose

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:44`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:642`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1111`, `specs/SPEC-017-network-stats-api.md:2085`

**Finding:** The v0.1.7 delta summary still says §9.4 pins only Shape A or Shape B; a deploy-gate line says "fail-closed burst"; and a Step 4.B test bullet says "Burst behavior." The binding v0.1.8 sections correctly require Shape C by default and no `burst=`.

**Risk:** Low. Nearby mandatory sections prevent a conforming implementer from configuring burst or choosing Shape A/B under locked grants. The stale terms are still wrong in a fresh kickoff prompt.

**Fix:** Reword to "single PostgreSQL transaction; v0.1.8 Shape C is the default" and "no-burst hard-limit behavior."

### CODE-R11-005 - LOW - Required-reading pointer sends implementers to the wrong SPEC-006 section

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:748`  
**Dependency evidence:** `specs/SPEC-006-buyer-api.md` current §5.4 and §8.3

**Finding:** The required-reading list still says to read SPEC-006 `§17` for header strip / `X-MacProvider-*` allowlists. In current SPEC-006 v0.9, that material is under §5.4 / §8.3, not §17.

**Risk:** Low. `X-Stats-Generated-At` does not collide with the `X-MacProvider-*` namespace and the prompt pins the stats header directly.

**Fix:** Point the dependency reading item at SPEC-006 §5.4 and §8.3.

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.8 fully, focusing on §3.7, §4.3, §5.1-§5.9, §6, §7.1-§7.6, §8, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-22.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package with `store` and `rollup` subpackages remains compatible with the existing explorer pattern while keeping stats out of explorer.
- Verified all prompt SPEC-017 `§X.Y` citations resolve under v0.1.8. Citations to SPEC-005 §4.3-§4.8 / §11.4 and SPEC-006 §17 were treated as dependency citations, not SPEC-017 drift.
- Verified prompt AC references enumerate AC-1 through AC-22 and map to current §10 content, apart from stale prose counts.
- Walked the prompt's grant inventory against locked SPEC §7.2 and table schemas. `stats_rollup_state` is the only table/grant addition that is not authorized by the locked SPEC; the optional `rewards_populated` storage is backed by §9.1a's implementation-authored storage allowance.
- Verified SPEC-005 v0.3 ledger denial targets exist: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
- Verified SPEC-002 v1.4 contains `provider_tokens` under §7.3 as the provider-token dependency surface.

## Category Walk

- **A. Section number drift:** PASS with LOW hygiene. SPEC-017 citations resolve under v0.1.8; the SPEC-006 dependency pointer is stale.
- **B. Postgres grant shape correctness:** FAIL HIGH. `stats_rollup_state` table/grants are outside the locked §7.2 / §9.1 inventory.
- **C. Go package boundary correctness:** PASS. `internal/stats`, `internal/stats/store`, and `internal/stats/rollup` boundaries match §7.6 and the explorer handler pattern.
- **D. Wire-contract correctness:** PASS with LOW hygiene. Token format, CORS 204, closed error vocabulary, status codes, cache directives, Vary rules, and `X-Stats-Generated-At` are aligned.
- **E. AC test-coverage mapping:** PASS with LOW hygiene. AC-1 through AC-22 have owners; two prose references still say 21.
- **F. Migration / IMPL-time decision drift:** FAIL HIGH via `stats_rollup_state`; dependency re-checks, hostname posture, and both backfill paths are otherwise gated.
- **G. Test-shape correctness:** FAIL HIGH. Rate-limit tests do not prove per-endpoint isolation, and the concrete keying examples can implement the wrong shared bucket.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB` pools, typed request context for bearer transfer, recover middleware, and default-off `last_used_at` worker posture are pinned.
- **I. Naming hygiene:** MIXED LOW. Role names, table names other than `stats_rollup_state`, CLI names, and event names are consistent; stale "burst" and "21 ACs" wording remains.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 11 is not code-mechanics ready. Most of the v0.1.8 re-anchor is correct: Shape C is the default rebuild path, AC-22 is present, the partner-key 601st-request correction is present, CORS/status/cache directives line up, and the stats package layout still matches the existing flat explorer handler pattern without extending explorer. The prompt also correctly keeps `partner_keys_writer` default-off under the locked column-scoped grant.

Two implementation-shaping issues remain. First, the new `stats_rollup_state` table is not in locked SPEC §9.1 / §9.1a / §6.1 / §6.5 / §5.4.1, and its `stats_reader` / `stats_rollup` grants are not in §7.2. SPEC §7.2.2 explicitly treats non-OLTP additional grants to `stats_rollup` as a contract violation, so this requires either removal or a SPEC bump. Second, the concrete rate-limit guidance keys the success buckets and nginx examples by IP or `partner_keys.id` only, while §5.6 requires per-endpoint limits. A conforming implementation could accidentally share quotas across `/overview`, `/leaderboard`, and `/health`.

The remaining items are low hygiene: two stale 21-AC references, stale Shape A/B and burst prose, and the wrong SPEC-006 section pointer. No fix prompt was drafted.
