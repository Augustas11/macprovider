# SPEC-017 IMPL Step 3 — Security Audit Round 2

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `66c63381a87356d3dd76cfbd5ef16856d1498c11` (`impl(017): Step 3 — round-1 audit fixes (3C + 6H + 3M across ARCH/CODE/SECURITY)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, and rate-limit reserve-then-refund.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `66c63381a87356d3dd76cfbd5ef16856d1498c11`, the round-1 Step 3 fix commit.
- `git diff --name-only bd68a0a..HEAD` — PASS; changed files are Step 3 stats handlers/middleware/store, coordinator mux wiring, stats module support/tests, and Step 3 audit prompt/audit files.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` — PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` — PASS; handler-package log calls are in recover/access middleware shape and rollup logs are outside this Step 3 request-path lens. No trace calls or raw `Authorization` print sites were found.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` — INFO; no matches. This differs from the prompt's older validation note because HEAD intentionally removed the prior no-op `ConstantTimeCompare` touch. Code inspection found no remaining in-process secret-derived equality comparison; token matching is `sha256` plus `SELECT ... WHERE token_hash = $1`.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` — PASS.
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` — PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` — PASS; no output.
- Additional coverage sweep: `rg -n "AC-18|AC-22|7-row|allowed_origins|stats_handler_panic|X-Api-Key|Cookie|X-Forwarded-For|stale not debited|Access-Control-Allow-Origin|subdomain|evil\.streamvc|portal\.streamvc|301st|partner projection" phase4-coordinator/internal/stats -g '*_test.go'` — FAIL coverage; no Step 3 tests were found for the security fixture set named below.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go` injects `statsstore.New(statsPools.Reader)` into `stats.NewMux` for `/v1/stats/*` and does not pass the rollup/admin pools to the handler. Request-path store methods are SELECT-only and do not query ledger tables, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS — redaction middleware stores the parsed bearer under unexported `authKey`, replaces `Authorization` with `REDACTED`, and now also strips `Cookie` and `X-Api-Key`; recover repeats the defense-in-depth strip. `dispatchAuth` hashes `[]byte(bearer)` with SHA-256 and the store selects by `token_hash`. No raw token response/log/trace/metric path was found.

C. Timing equivalence: FAIL (coverage) — implementation ordering is correct: rows 3/5/6/7 run `sha256 + LookupPartnerKeyByHash` before row presence, revocation, or Origin allowlist branching. However, the required sustained-rate AC-18 timing fixture was not present in Step 3 tests.

D. CORS + Origin: FAIL (coverage) — implementation enforces RFC 6454 normalization, rejects malformed origins as absent, omits ACAO on 401, and partner projection never calls the public `ACAO: *` branch. Preflight max-age defaults to 60 and clamps at 300. However, Step 3 tests do not drive the §5.7 7-row CORS matrix or sibling-subdomain rejection fixtures.

E. Rate-limit security: FAIL (coverage) — implementation reserves the auth-failure bucket before auth dispatch, refunds it for partner success, ignores spoofed XFF unless the immediate peer is trusted, and refunds post-auth success buckets on non-2xx responses. However, Step 3 tests do not cover AC-22 301st invalid-bearer behavior, untrusted/trusted XFF split, valid-key auth-failure refund, or stale-503-not-debited behavior.

F. Recover + redaction: FAIL (coverage) — recover wraps the entire mux returned by `Handler()`, including OPTIONS and 405 paths, and strips `Authorization`, `Cookie`, and `X-Api-Key` before logging. Public panic logs use event/path/method/type without panic string or stack. However, no Step 3 AC-15 panic/log/trace redaction sweep fixture was found for raw token, `token_hash`, random-substring, `Cookie`, or `X-Api-Key`.

G. Surface attack tests: PASS — HEAD drops body bytes in both success and error writers, 304 omits `X-Stats-Generated-At`, 405 returns `Allow: GET, HEAD, OPTIONS`, and strict endpoint matching rejects suffix paths such as `/v1/stats/overview/extra`. Error envelopes use closed generic messages and do not include SQL errors, DSNs, hostnames, internal IPs, stacks, raw tokens, or token hashes.

H. Step 4 boundary: PASS — Step 3 does not add partner-key CLI issuance/rotation/revocation, nginx config, or Prometheus metric label authoring. Those attack surfaces remain deferred to Step 4.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:206`
   - Evidence: the current handler integration tests cover invalid/malformed Authorization, generic preflight, stale overview 503, 405, HEAD body suppression, public projection totals, 304, and health degradation. A targeted grep across Step 3 tests found no fixtures for AC-18 timing equivalence, the full §5.7 CORS decision table, sibling-subdomain rejection, AC-22 auth-failure limiter/XFF behavior, stale-503-not-debited accounting, or AC-15 recover/redaction sweeps for raw token / `token_hash` / random substring / `Cookie` / `X-Api-Key`.
   - Why: The Step 3 handler is the first public partner-key attack surface. The implementation currently looks correct by inspection, but the locked BUILD prompt and this audit prompt require these security fixtures to prevent future regressions in the exact controls that carry timing-oracle, CORS, raw-token leak, and rate-limit-bypass risk. The severity model explicitly treats missing §5.7 fixtures as MEDIUM defense-in-depth gaps; this is broader than one missing row.
   - Fix: Add Step 3 tests for: AC-18 rows 5/6/7 at sustained rate below 270 rpm; row 3 absent/malformed Origin after the same hash+SELECT path; all §5.7 CORS rows including partner projection never `ACAO: *` and rejected-keyed 401 omitting ACAO; sibling subdomain exact-match rejection; AC-22 301st invalid-bearer pre-SELECT cap plus trusted/untrusted XFF behavior; valid partner-key auth-failure refund; stale 503 not debiting success buckets; AC-15 panic/log/trace redaction with `Authorization`, `Cookie`, and `X-Api-Key`.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/middleware.go:50` strips `Authorization`, stores the parsed bearer only under an unexported typed context key, and now redacts `Cookie` plus `X-Api-Key`.
- `phase4-coordinator/internal/stats/middleware.go:85` recover middleware repeats the header strip and logs only panic type/path/method at error level.
- `phase4-coordinator/internal/stats/auth.go:147` computes SHA-256 before row presence, revocation, or Origin allowlist checks for keyed requests.
- `phase4-coordinator/internal/stats/mux.go:115` omits ACAO on rejected keyed 401s.
- `phase4-coordinator/internal/stats/mux.go:131` probes overview freshness before success-bucket debit, and `statusRecorder` refunds non-2xx handler results.
- `phase4-coordinator/internal/stats/handlers.go:706` now requires exact endpoint path matches.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56` allowlists dynamic table/order SQL through validated `window` and `sort`.
- `phase4-coordinator/cmd/coordinator/main.go:493` mounts handlers with `statsPools.Reader` only.

## Positive Security Observations
- The round-1 SECURITY M2/L1/L2 and M1 fixes are present: header defense-in-depth stripping, 401 ACAO omission, strict endpoint match, and freshness-before-debit/refund behavior.
- Request-path DB access stays on `stats_reader`; rollup/admin pools are not injected into the public handler stack.
- No raw bearer, token hash, prefix, or label was found in response/error/log/trace/metric code paths under the Step 3 handler lens.
- The partner-key path returns private cache headers and partner Vary only on partner projection; rejected keyed requests use public Vary without CORS allow headers.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 8

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
