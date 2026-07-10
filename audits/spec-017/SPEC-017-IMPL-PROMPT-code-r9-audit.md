# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 9

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 1 HIGH, 2 MEDIUM, 1 LOW.

The v0.1.8 re-anchor absorbed the prior Shape C, AC-8 burst, auth-failure tier, `X-Stats-Generated-At`, and CORS row-number blockers. The remaining code-mechanics issues are local to the IMPL prompt: one middleware directive over-scopes the auth-failure limiter onto absent and valid Authorization traffic, the optional nginx split-location sketch is not mechanically pinned enough to be safely implemented, and the Step 2 atomicity test still names Shape A/B success assertions after the prompt mandates Shape C.

## Findings

### CODE-R9-001 - HIGH - Auth-failure limiter directive caps absent/valid traffic at the failed-bearer tier

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:418-421`, conflicting later with `specs/BUILD_SPEC_017_IMPL_PROMPT.md:443-445`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1105-1109`, `specs/SPEC-017-network-stats-api.md:1129-1143`, `specs/SPEC-017-network-stats-api.md:1145-1170`, `specs/SPEC-017-network-stats-api.md:2333-2341`

**Finding:** The middleware stack says the auth-failure tier "limits any `/v1/stats/*` request that produces a 401 ... AND any request with absent/valid Authorization" and returns 429 before the auth dispatcher runs. Locked §5.6 scopes that 300 rpm bucket to `Authorization`-present requests that produce 401 under §5.4.3 rows 3/5/6/7. Anonymous public traffic remains governed by the 60 rpm public tier, and valid partner-key traffic remains governed by the per-key `rate_limit_rpm` default 600.

The same prompt later states the correct three-tier model, but the pinned stack order is the implementation surface. An author following line 421 literally can reject the 301st valid partner request from one IP before the handler can apply the 600 rpm partner bucket.

**Risk:** Code compiles and runs, but a valid partner key configured at the default 600 rpm can be throttled by the 300 rpm failed-bearer bucket. That violates §5.6 partner-tier semantics and the §5.6 keyed-bypass companion test, and can also double-limit anonymous traffic on the direct-to-coordinator fallback path.

**Fix:** Reword middleware step 4 to skip absent Authorization entirely and to treat Authorization-present requests as a pre-auth reservation only for failed-bearer accounting. A valid-key success should not debit the auth-failure bucket; if the implementation must reserve before lookup to satisfy AC-22, it should refund/drop the reservation on 200 partner projection. Keep 401 rows 3/5/6/7 counted uniformly.

### CODE-R9-002 - MEDIUM - Nginx split-location option is underspecified and easy to implement as an invalid or non-bypassing config

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:553-574`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1145-1170`

**Finding:** The prompt offers two Authorization-aware nginx shapes. Shape (a), the `map $http_authorization $public_rl_key` approach, is mechanically concrete. Shape (b) is shown as:

```nginx
location /v1/stats/leaderboard {
    if ($http_authorization != "") { ... no public limit_req ... }
    limit_req zone=stats_public nodelay;
    limit_req_status 429;
    proxy_pass http://coordinator;
}
```

That sketch does not define a valid nginx control-flow shape that actually removes `limit_req` for Authorization-bearing requests. A naive implementation either fails `nginx -t` by putting unsupported directives inside `if`, or leaves `limit_req` active for the same location and still throttles keyed traffic at the public tier.

**Risk:** Two conforming authors can pick different interpretations. One uses the map and passes; another copies the split-location idea and ships an invalid nginx config or an edge config that fails the keyed-through-nginx bypass companion test.

**Fix:** Either remove Shape (b) and require the map-based bypass for v0.1, or replace it with a fully valid nginx pattern such as an `error_page`/named-location dispatch where the Authorization-bearing named location contains no public `limit_req`. Add `nginx -t` plus a valid-key >60-through-nginx test to Step 4.B.

### CODE-R9-003 - MEDIUM - Step 2 rebuild atomicity success test still asserts Shape A/B artifacts after v0.1 mandates Shape C

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:255-270`, stale test directive at `specs/BUILD_SPEC_017_IMPL_PROMPT.md:308`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:2093-2102`, `specs/SPEC-017-network-stats-api.md:2125-2138`

**Finding:** The prompt correctly pins Shape C as the v0.1 default and says Shape A/B require widened grants. But the Step 2 integration test still says a successful rebuild should assert "the swap landed atomically" with examples for Shape B (`_old` table gone) and Shape A (temp table dropped). Under Shape C there is no swap, no `_old` table, and no temp table. The actual Shape C success condition is that concurrent `stats_reader` SELECTs never observe an empty table and the post-commit rows equal the rebuilt source query.

**Risk:** Test authors can write non-applicable Shape A/B artifact assertions against a Shape C implementation, or omit the Shape C positive assertion and only test rollback. That leaves §9.4's MVCC no-empty-state guarantee under-specified.

**Fix:** Replace the Shape A/B example with Shape C-specific checks: deliberately abort inside the transaction and assert the pre-rebuild rows remain; run a successful Shape C rebuild while a concurrent `stats_reader` transaction repeatedly SELECTs and assert every observation is either the old full set or the new full set, never zero/partial; after commit, assert live rows equal the rebuilt source query.

### CODE-R9-004 - LOW - Stale "burst" and Shape A/B language remains as naming hygiene

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:44`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:599`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1111-1121`, `specs/SPEC-017-network-stats-api.md:2093-2102`

**Finding:** A few non-primary prose lines still carry pre-v0.1.8 terminology:

- The v0.1.7 delta summary says §9.4 pins Shape A/B, although v0.1.8 supersedes that with Shape C as the required v0.1 implementation.
- The nginx deploy-gate line says "fail-closed burst (§5.6 enforced via `nodelay`)" even though v0.1.8 removed burst entirely.
- The Step 4.B test list has a "Burst behavior" bullet; the intended assertion is "no burst/delay behavior."

**Risk:** Low, because nearby binding text correctly says no `burst=` and Shape C is the v0.1 default. The stale terms still create audit churn and grep-level confusion.

**Fix:** Change the §9.4 delta line to "single PostgreSQL transaction; v0.1.8 adds Shape C as default." Change "fail-closed burst" / "Burst behavior" to "no-burst hard-limit behavior."

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.8 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.2, §7.6, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-22.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package with `store` and `rollup` subpackages remains consistent with the existing explorer pattern, while keeping stats out of explorer.
- Verified `phase4-coordinator/go.mod` module path is `github.com/augstar/macprovider-coordinator`; the prompt's import-graph fixture guidance uses the correct module path.
- Verified SPEC-005 v0.3 line 3 and table inventory: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs` exist in §4.3-§4.6 and are valid AC-9 denial targets.
- Verified SPEC-002 v1.4, SPEC-006 v0.9, SPEC-014 v0.8, and SPEC-016 v0.1.19 line-3 versions align with the prompt's dependency references.
- Verified all prompt AC references are AC-1 through AC-22 and each maps to a current §10 AC.
- Verified Postgres grants named in the prompt are syntactically valid PostgreSQL shapes: table grants use `GRANT SELECT... ON <tables> TO <role>`, backing sequences use `GRANT USAGE, SELECT ON SEQUENCE ...`, and `partner_keys_writer` is correctly default-off because the locked column-scoped UPDATE grant cannot support the natural `WHERE id = $2` worker query without additional SELECT.

## Category Walk

- **A. Section number drift:** PASS with LOW hygiene. SPEC-017 section citations resolve under v0.1.8; non-SPEC refs such as SPEC-006 §17 and SPEC-005 §11.4 are dependency refs, not SPEC-017 drift. Stale Shape A/B wording remains in a summary line.
- **B. Postgres grant shape correctness:** PASS. Table names and sequence grants match the locked schemas; the prompt correctly avoids creating `partner_keys_writer` by default.
- **C. Go package boundary correctness:** PASS. `internal/stats`, `internal/stats/store`, and `internal/stats/rollup` boundaries are consistent with §7.6 and the existing `internal/explorer` package pattern.
- **D. Wire-contract correctness:** FAIL on rate-limit scoping. Partner-key length math, CORS 204, closed error vocabulary, status codes, cache-control values, Vary rules, and `X-Stats-Generated-At` are aligned.
- **E. AC test-coverage mapping:** MIXED. AC-1 through AC-22 have owners. AC-22 is covered, but its middleware directive over-scopes the 300 rpm bucket; Step 2's §9.4 test needs Shape C-specific success assertions.
- **F. Migration / IMPL-time decision drift:** PASS. The prompt gates dependency re-checks at IMPL time, implements both hostname and backfill modes, and keeps operator cutover choices out of code-write gates.
- **G. Test-shape correctness:** MIXED. Most tests are mechanically writable. Step 2 Shape C atomicity and Step 4.B nginx split-location tests need tightening.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB` pools, typed context token handoff, recover middleware, and default-off `last_used_at` worker posture are pinned clearly.
- **I. Naming hygiene:** MIXED. Role names, table names, CLI names, and event names are consistent. Stale "burst" wording should be renamed to no-burst hard-limit behavior.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 9 is close but not code-mechanics ready. The IMPL prompt is now correctly anchored to SPEC-017 v0.1.8: Shape C exists in the locked SPEC, burst has been removed, AC-22 is present, the partner-key token math is right, CORS preflight is 204-only, cache directives match §5.1/§5.2/§5.3, and all AC-1 through AC-22 references map to current §10 content. The Postgres grants and package boundaries also check out against the locked schemas and the existing `internal/explorer` pattern.

The main remaining blocker is the Step 3 middleware stack: it says the auth-failure limiter applies to requests with absent or valid Authorization. Locked §5.6 scopes that 300 rpm bucket only to Authorization-present requests that become 401s; valid partner traffic must be governed by the per-key 600 rpm bucket. The prompt should describe a pre-auth failed-bearer reservation that is skipped for anonymous traffic and refunded/dropped on valid-key success.

Two medium test/config mechanics gaps remain. The nginx split-location option is too hand-wavy to guarantee a valid public-limiter bypass, and the Step 2 atomicity test still names Shape A/B artifacts instead of Shape C's no-empty-state MVCC assertion. Low stale "burst" and Shape A/B wording should be cleaned up. No fix prompt was drafted.
