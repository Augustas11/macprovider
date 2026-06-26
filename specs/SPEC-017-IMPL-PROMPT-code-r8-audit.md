# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 8

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.7 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 2 HIGH, 2 MEDIUM, 1 LOW.

The r8 fix pass closed the round-7 mechanics defects around invalid-bearer cache behavior, optional `partner_keys_writer` startup, CLI operator DSN, malformed-Origin expectations, HEAD coverage, and stale reading-list hygiene. The remaining blockers are all in the IMPL prompt itself: it now directs an implementation shape that the locked SPEC does not allow, and it keeps Step 4.B/AC-8 as a v0.1.7 completion deliverable while also declaring it blocked on a future SPEC reconciliation.

## Findings

### CODE-R8-001 - HIGH - Prompt directs Shape C before the locked SPEC permits Shape C

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:248-263`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1997-2024`, `specs/SPEC-017-network-stats-api.md:1526-1556`

**Finding:** The prompt says the IMPL author MUST use "Shape C" (`DELETE FROM stats_leaderboard_all; INSERT ...` inside one transaction) until a SPEC v0.1.8 candidate adds Shape C to §9.4 or widens the grants. But locked SPEC-017 v0.1.7 §9.4 says two implementation shapes are acceptable: Shape A temp-table swap and Shape B atomic rename. Shape C is not an allowed §9.4 shape in the controlling contract.

The prompt correctly observes that Shapes A/B are not executable by the locked `stats_rollup` grant set, but it resolves that by adding a third implementation shape in the prompt instead of blocking on a locked SPEC update.

**Risk:** A conforming IMPL author following the prompt will ship code that compiles and likely runs, but implements a rebuild algorithm not allowed by the locked SPEC. Any §9.4 conformance test or audit that asserts the locked A/B shape set will fail.

**Fix:** Do not authorize Shape C under v0.1.7. Either block Step 2 nightly rebuild implementation until SPEC v0.1.8 locks Shape C or a widened grant shape, or change the locked SPEC first and then update the prompt. The IMPL prompt must not be the surface that expands §9.4.

### CODE-R8-002 - HIGH - Step 4.B is both hard-blocked and required for v0.1.7 completion

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:531-547`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:557-560`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:624-650`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:721-739`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1063-1071`, `specs/SPEC-017-network-stats-api.md:2144-2146`

**Finding:** The prompt now says Step 4.B production nginx rate-limit config is HARD BLOCKED until SPEC v0.1.8 reconciles §5.6's `60 req/min, burst 120` public tier with AC-8's "61st request in 60s returns 429." That is the right direction compared with the old R2 waiver, but the rest of the same prompt still treats Step 4.B as a normal Step 4 deliverable under v0.1.7:

- The AC matrix assigns AC-8 to Step 4.B.
- End-of-implementation requires all four step PRs merged and all 21 ACs verified.
- The final done checklist requires the AC-8 61st request result "once the §5.6/AC-8 SPEC reconciliation has landed," while the IMPL prompt itself is still anchored to v0.1.7.

**Risk:** Two conforming implementers can resolve this differently: one stops Step 4.B and cannot finish v0.1.7, while another uses the test-only no-burst harness or `limit_req ... nodelay` directive as production config and violates §5.6. Either path breaks the stated implementation workflow or the locked rate-limit contract.

**Fix:** Make the block structurally consistent. Either mark the whole SPEC-017 IMPL kickoff blocked before Step 4.B/production cutover until SPEC v0.1.8 is locked, or remove Step 4.B from the v0.1.7 deliverable/AC matrix and explicitly define a post-reconciliation continuation. Also remove the stale "Path R1/R2" final-checklist reference.

### CODE-R8-003 - MEDIUM - Nginx public `limit_req` directive can accidentally throttle partner-key traffic

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:531-535`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:549`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:559-564`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1063-1071`, `specs/SPEC-017-network-stats-api.md:1044-1050`

**Finding:** The prompt says to apply `limit_req zone=<name> nodelay;` to each endpoint location, then later says partner tier requests do not use nginx `limit_req` and are limited in-process by `partner_keys.id`. In nginx, a `limit_req` placed on the `/v1/stats/leaderboard` location will also apply to requests carrying `Authorization` unless the config explicitly maps Authorization-bearing requests out of the public zone or uses an equivalent bypass.

The prompt does require `proxy_cache_bypass $http_authorization` for cache isolation, but it does not give the analogous rate-limit bypass/keying shape.

**Risk:** A mechanically natural nginx config will enforce the public 60 rpm limiter before the coordinator sees valid partner-key requests, so a partner key configured for 600 rpm can still get public-tier 429s at the edge. That compiles and deploys, but fails the §5.6 partner-tier contract once a keyed-through-nginx rate test is written.

**Fix:** Pin the nginx shape: e.g. use an nginx `map` so the public `limit_req_zone` key is empty for requests with `Authorization`, or otherwise split keyed traffic out of the public limiter before `limit_req` runs. Add a Step 4.B test where a valid partner key sends more than 60 requests through nginx and is not rejected by the public limiter; the in-process partner bucket remains authoritative.

### CODE-R8-004 - MEDIUM - Blanket `X-Stats-Generated-At` test conflicts with the 304 header exception

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:374`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:398`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:445-457`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1161-1163`, `specs/SPEC-017-network-stats-api.md:2161-2163`

**Finding:** The prompt correctly says a 304 carries `ETag`, `Cache-Control`, and `Vary` per RFC 7232. But a few lines later it says `X-Stats-Generated-At` is present on every `/v1/stats/*` response, and the Step 3 test list repeats that blanket assertion. Locked §5.9 says 304 is exempt and MUST be returned with an empty body and only the required RFC 7232 headers (`ETag`, `Cache-Control`, `Vary`).

**Risk:** One author will include `X-Stats-Generated-At` on 304 because the prompt says every response; another will omit it because §5.9 says only the 304 headers. A strict AC-12/§5.9 test can fail either the implementation or the prompt's blanket test.

**Fix:** Narrow the directive to "every non-304 `/v1/stats/*` response" or explicitly say the 304 path is exempt from `X-Stats-Generated-At` per §5.9.

### CODE-R8-005 - LOW - §5.7 partner-key row numbers are stale in one prose sentence

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:363-368`, corrected later at `specs/BUILD_SPEC_017_IMPL_PROMPT.md:460`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1087-1095`

**Finding:** The prompt says partner-key projection responses are "rows 2/3/4 of the v0.1.7 §5.7 table." In locked v0.1.7, row 2 is the public no-key leaderboard branch, and the partner-key projection rows are 3, 4, and 5. The later Step 3 CORS test correctly names rows 3, 4, and 5, so this is localized prose drift.

**Risk:** Minor audit/test authoring confusion. A reader following the stale prose might include public row 2 in the partner-key-only `ACAO: *` sweep and miss row 5.

**Fix:** Change "rows 2/3/4" to "rows 3/4/5."

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.7 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.2, §7.6, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-21.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package with `store` and `rollup` subpackages remains consistent with the existing explorer pattern.
- Verified `phase4-coordinator/go.mod` module path is `github.com/augstar/macprovider-coordinator`; the prompt's import-graph fixture guidance uses the correct module path.
- Verified SPEC-005 v0.3 contains `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
- Verified SPEC-002 v1.4 contains `provider_tokens` and the `auth.require_provider_tokens` trust-source gate the prompt asks the IMPL author to re-check.

## Category Walk

- **A. Section number drift:** FAIL. Most § references resolve, but Shape C is not in locked §9.4, and one §5.7 row-number sentence is stale.
- **B. Postgres grant shape correctness:** MIXED. The explicit grants are syntactically valid and role-scoped. The prompt correctly identifies A/B rebuild grant mismatch, but then authorizes a non-SPEC Shape C before the SPEC changes.
- **C. Go package boundary correctness:** PASS. `internal/stats`, `internal/stats/store`, and `internal/stats/rollup` boundaries are consistent with §7.6 and the existing flat `internal/explorer` handler pattern.
- **D. Wire-contract correctness:** MIXED. Partner-key token length, CORS 204, closed error vocabulary, cache directives, Vary rules, and status codes are mostly aligned. The 304 vs `X-Stats-Generated-At` blanket directive needs narrowing.
- **E. AC test-coverage mapping:** FAIL. AC-1 through AC-21 are mapped, but AC-8 is assigned to a Step 4.B path the prompt itself hard-blocks pending SPEC v0.1.8.
- **F. Migration / IMPL-time decision drift:** FAIL. OLTP source grants and hostname/backfill posture are handled, but Step 2 and Step 4.B both require future SPEC reconciliation while still being presented inside a v0.1.7 implementation prompt.
- **G. Test-shape correctness:** MIXED. Most handler/rollup/CLI fixture shapes are mechanically writable. The Step 4.B nginx tests need a keyed-through-nginx rate-limit bypass test, and AC-8 sequencing is inconsistent with the hard block.
- **H. Idiomatic Go correctness:** PASS. Per-role `*sql.DB` pools, middleware order, typed context key guidance, and default-off `last_used_at` worker posture are pinned clearly.
- **I. Naming hygiene:** MIXED. Role names, table names, CLI names, and event names are consistent. The §5.7 row-number prose and final "Path R1/R2" reference are stale.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line and grant-dependent SQL/nginx path.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 8 is not code-mechanics ready. The r8 fix pass successfully closes the round-7 cache, writer-DSN, CLI-DSN, malformed-Origin, HEAD, and reading-list issues, but it introduces or leaves unresolved two larger contract-mechanics blockers. First, Step 2 now tells the implementer to use Shape C (`DELETE` + `INSERT` in one transaction) for nightly rebuilds even though locked SPEC-017 v0.1.7 §9.4 permits only Shape A or Shape B. Shape C may be executable under `stats_rollup`, but the IMPL prompt cannot expand the locked SPEC. Second, Step 4.B is declared hard-blocked on a future SPEC v0.1.8 reconciliation of §5.6 vs AC-8, while the same prompt still assigns AC-8 to Step 4.B and requires all four step PRs plus all 21 ACs for v0.1.7 completion.

Two medium mechanics gaps remain: the nginx public `limit_req` directive can accidentally throttle valid partner-key requests at the anonymous tier unless the prompt pins an Authorization-aware bypass, and the blanket `X-Stats-Generated-At` test conflicts with the §5.9 304 header exception. One low row-number typo remains in the §5.7 partner-key CORS prose. Grant syntax, package paths, token length math, CORS 204 behavior, closed error codes, cache-control values, AC references, and existing explorer-package alignment otherwise checked out. No fix prompt was drafted.
