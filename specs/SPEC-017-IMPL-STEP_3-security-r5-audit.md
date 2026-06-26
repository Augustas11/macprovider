# SPEC-017 IMPL Step 3 — Security Audit Round 5

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `220181a48e7b8bdca705318207d6d5ff514fba87` (`impl(017): Step 3 — round-4 audit fixes (ARCH 1M + SECURITY 1M + test coverage)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r4-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, rate-limit reserve-then-refund, and Step 3-owned test matrix.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r2-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r3-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r4-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `220181a48e7b8bdca705318207d6d5ff514fba87`. This round-4 fix commit changes `phase4-coordinator/internal/stats/handlers_integration_test.go`, `phase4-coordinator/internal/stats/mux.go`, the Step 3 ARCH audit prompt, and prior r4 audit files.
- `git diff --name-only bd68a0a..HEAD` — PASS; Step 3 diff includes `.golangci.yml`, coordinator mux wiring, stats handler/middleware/store/support/test files, stats module support, Step 3 audit prompts, and prior Step 3 audit artifacts.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` — PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` — PASS with scope note; request-path log surfaces are recover/access middleware and tests. No raw `Authorization` print/trace call site was found. Rollup logs/tests are outside this Step 3 request-path lens.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` — INFO deviation; no matches. Code inspection found no in-process equality comparison over token-derived bytes. The dispatcher hashes `[]byte(bearer)` with SHA-256 and performs `SELECT ... WHERE token_hash = $1`; timing equivalence is covered by shared hash+SELECT work plus AC-18 latency testing.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` — PASS:
  - `internal/stats`
  - `internal/stats/migrations`
  - `internal/stats/rollup`
  - `internal/stats/store` (`[no test files]`)
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` — PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` — PASS; no output.
- Additional security coverage sweep: `rg -n "func Test|AC18|AC-18|Timing|timing|CORS|Origin|evil\.streamvc|portal\.streamvc|X-Forwarded-For|trusted|AuthFailure|auth-failure|refund|stale|panic|trace|token_hash|random|Cookie|X-Api-Key|HEAD|DELETE|PATCH|PUT|405|Max-Age|subtle|ConstantTimeCompare" phase4-coordinator/internal/stats -g '*_test.go'` — FAIL coverage; HEAD added AC-18, stale-503-not-debited, PUT/DELETE/PATCH 405, and one partner-projection CORS fixture, but still lacks the full lock-pinned security matrix listed in MEDIUM 1.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go:493` mounts `/v1/stats/` with `statsstore.New(statsPools.Reader)` only. Request-path store methods use SELECTs against stats tables, `stats_rewards_populated`, `provider_visibility`, and `partner_keys`; no handler/store path imports `internal/stats/migrations`, receives an admin/rollup pool, or selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS — `redactionContextMiddleware` parses the bearer once, stores it under unexported `authKey`, replaces `Authorization` with `REDACTED`, and strips `Cookie` plus `X-Api-Key`. `recoverMiddleware` repeats the strip. `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash`. No raw token, token hash, prefix, or label response/log/trace/metric projection was found in the Step 3 handler path.

C. Timing equivalence: FAIL (coverage) — implementation ordering is correct by inspection: keyed `/leaderboard` requests perform `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching, so rows 3/5/6/7 share the required work. However, `TestAC18_TimingEquivalenceRows5_6_7` uses 30 samples per row at `handlers_integration_test.go:905`, while BUILD Step 3 requires 100+ requests per row, and row 3 same-work/malformed-Origin timing is not separately asserted.

D. CORS + Origin: FAIL (coverage) — implementation normalizes Origin per RFC 6454, preflight is key-agnostic with default max-age 60 and cap 300, partner projection never emits `ACAO: *`, and rejected keyed 401s omit ACAO. Tests still do not drive the full §5.7 seven-row matrix, active-key-origin preflight union, sibling-subdomain exact-match rejection, rejected keyed 401 ACAO omission, server-to-server empty-allowlist omission, or malformed-Origin row-3 behavior.

E. Rate-limit security: FAIL (coverage) — auth-failure limiting is scoped to `/leaderboard`, reserves before auth dispatch, refunds on valid auth success, keys by trusted-proxy-aware client IP, and ignores spoofed XFF when no trusted proxy is configured by implementation. Tests cover the invalid-bearer 300 cap and absent-Authorization scoping, but still lack trusted/untrusted `X-Forwarded-For` split and high-volume valid-partner refund coverage proving valid keys are not capped by the auth-failure tier.

F. Recover + redaction: FAIL (coverage) — recover wraps the full `Handler()` stack including OPTIONS and 405 paths, strips `Authorization` / `Cookie` / `X-Api-Key`, logs only event/path/method/panic type at error level, and keeps stack output on Debug. The AC-15 test remains a non-panic structured-log sweep; it does not exercise panic-log redaction, trace-span redaction, `token_hash`, or random-token substring checks.

G. Surface attack tests: FAIL (coverage) — implementation suppresses HEAD body bytes in success/error writers, suppresses `X-Stats-Generated-At` on 304, exact-matches `/v1/stats/{overview,leaderboard,health}`, and returns 405 with `Allow: GET, HEAD, OPTIONS`. Tests now cover anonymous HEAD and PUT/DELETE/PATCH 405, but still lack partner-key HEAD body/header parity. Error envelopes are generic and do not include SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

H. Step 4 boundary: PASS — Step 3 owns no partner-key CLI issuance/rotation/revocation surface, no nginx config, and no Prometheus metric-label authoring. Step 4-only content remains in spec/audit prompt material or comments, not executable Step 3 surface.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:803`
   - Evidence: HEAD added several useful fixtures, but the remaining Step 3 security matrix is still partial. `TestAC11_PanicRecoveryRefundsSuccessBucket` explicitly says it cannot inject a real panic and uses 50 bad-request 400s as a representative non-2xx path (`handlers_integration_test.go:806-813`). `TestAC18_TimingEquivalenceRows5_6_7` uses 30 samples per row rather than the BUILD-required 100+ (`handlers_integration_test.go:905-917`) and does not pin row 3 malformed/absent-Origin timing. `TestPartnerProjectionNeverACAOStar` drives only one matched-Origin partner projection (`handlers_integration_test.go:983-1024`), not all seven §5.7 rows. Targeted grep found no trusted/untrusted XFF split, no high-volume valid partner-key auth-failure refund test, no panic-log/trace-span redaction sweep for raw token / `token_hash` / random substring / `Cookie` / `X-Api-Key`, and no partner-key HEAD parity fixture.
   - Why: Step 3 is the first public partner-key attack surface. These fixtures are the regression locks for the exact security controls that prevent timing oracle, CORS exposure, spoofed-XFF rate-limit bypass, valid-key double-throttling, panic/trace token leaks, and keyed HEAD information leaks. The round-4 coverage blocker was narrowed by HEAD but not closed.
   - Fix: Add Step 3 tests for a real injected panic through the full stats mux, including 500 envelope, process survival, success-bucket refund, and panic-log redaction; AC-18 rows 5/6/7 with 100+ requests per row at <=270 rpm plus row 3 absent/malformed-Origin same-work coverage; all seven §5.7 CORS rows including active-key-origin preflight union, rejected keyed 401 omitting ACAO, server-to-server empty-allowlist ACAO omission, sibling-subdomain exact-match rejection, and RFC 6454 malformed-Origin handling; trusted and untrusted XFF behavior; valid partner-key auth-failure refund at a volume above 300 but below partner `rate_limit_rpm`; trace-span redaction; and partner-key HEAD body length zero plus header parity.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/mux.go:202` closes the round-4 SECURITY M1 panic-refund code gap by refunding the success bucket when `rec.status == 0` before the outer recover emits the 500.
- `phase4-coordinator/internal/stats/cors.go:64` includes active `partner_keys.allowed_origins` in the preflight global allowlist union, so key-row partner origins are not excluded from key-agnostic preflight.
- `phase4-coordinator/internal/stats/mux.go:115` omits ACAO on rejected keyed 401s, matching §5.7 rejected-key rows.
- `phase4-coordinator/internal/stats/ratelimit.go:99` ignores `X-Forwarded-For` unless the immediate peer is in the trusted-proxy allowlist.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56` allowlists dynamic SQL table/order identifiers through validated `window` and `sort`, preventing user-controlled SQL identifier injection.
- `phase4-coordinator/internal/stats/origin.go:28` applies lowercase scheme/host, IDN-to-Punycode, default-port stripping, and malformed path/query/fragment handling.

## Positive Security Observations
- Request-path DB access remains isolated to `stats_reader`; rollup/admin pools are not exposed to public handlers.
- Raw bearer material is parsed once, stored only in request context under an unexported key, hashed by the auth dispatcher, and not serialized or logged by Step 3 code.
- The keyed auth dispatcher preserves the important timing ordering by computing SHA-256 and performing the `partner_keys` lookup before revocation or Origin decisions.
- Partner-key projection CORS omits `ACAO: *`; server-to-server partner responses omit ACAO when Origin is absent by implementation.
- Error envelopes use a closed code vocabulary and generic messages without SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 6

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
