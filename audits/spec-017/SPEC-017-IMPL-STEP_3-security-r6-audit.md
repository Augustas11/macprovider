# SPEC-017 IMPL Step 3 — Security Audit Round 6

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `f54b3d18c2377722004d96b614eac145d801e649` (`impl(017): Step 3 — round-5 test coverage (CODE M + SECURITY M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r5-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, rate-limit reserve-then-refund, and Step 3-owned security test matrix.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r2-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r3-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r4-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r5-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`. No repo-root `MEMORY.md` file exists in this worktree.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `f54b3d18c2377722004d96b614eac145d801e649`. The round-5 coverage commit changes `phase4-coordinator/internal/stats/handlers_integration_test.go`, `phase4-coordinator/internal/stats/middleware.go`, and prior r5 ARCH/CODE/SECURITY audit files.
- `git diff --name-only bd68a0a..HEAD` — PASS; Step 3 diff includes coordinator mux wiring, stats handler/middleware/store/support/test files, stats module support, Step 3 audit prompts, and prior Step 3 audit artifacts.
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
- Additional security coverage sweep: `rg -n "func Test|AC18|AC-18|Timing|timing|CORS|Origin|evil\.streamvc|portal\.streamvc|X-Forwarded-For|trusted|AuthFailure|auth-failure|refund|stale|panic|trace|token_hash|random|Cookie|X-Api-Key|HEAD|DELETE|PATCH|PUT|405|Max-Age|subtle|ConstantTimeCompare" phase4-coordinator/internal/stats -g '*_test.go'` — FAIL coverage; HEAD added real panic recovery, partner HEAD parity, all-window partial-history coverage, and trusted/untrusted XFF, but still leaves the lock-pinned coverage gaps listed in MEDIUM 1.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go:493` mounts `/v1/stats/` with `statsstore.New(statsPools.Reader)` only. Request-path store methods use SELECTs against stats tables, `stats_rewards_populated`, `provider_visibility`, and `partner_keys`; no handler/store path imports `internal/stats/migrations`, receives an admin/rollup pool, or selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS — `redactionContextMiddleware` parses the bearer once, stores it under unexported `authKey`, replaces `Authorization` with `REDACTED`, and strips `Cookie` plus `X-Api-Key`. `recoverMiddleware` repeats the strip. `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash`. No raw token, token hash, prefix, or label response/log/trace/metric projection was found in the Step 3 handler path.

C. Timing equivalence: FAIL (coverage) — implementation ordering remains correct by inspection: keyed `/leaderboard` requests perform `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching, so rows 3/5/6/7 share the required work. However, `TestAC18_TimingEquivalenceRows5_6_7` still uses 30 samples per row, not the BUILD-required 100+ requests per row, and row 3 absent/malformed-Origin same-work timing is not separately asserted.

D. CORS + Origin: FAIL (coverage) — implementation normalizes Origin per RFC 6454, preflight is key-agnostic with default max-age 60 and cap 300, partner projection never emits `ACAO: *`, and rejected keyed 401s omit ACAO. Tests still do not drive the full §5.7 seven-row matrix, active-key-origin preflight union, sibling-subdomain exact-match rejection, rejected keyed 401 ACAO omission beyond row 6, server-to-server empty-allowlist omission, or malformed-Origin row-3 behavior.

E. Rate-limit security: FAIL (coverage) — auth-failure limiting is scoped to `/leaderboard`, reserves before auth dispatch, refunds on valid auth success, keys by trusted-proxy-aware client IP, and now has trusted/untrusted XFF fixtures. Tests still lack a high-volume valid partner-key auth-failure refund fixture proving valid keys above 300 but below `rate_limit_rpm` are not capped by the auth-failure tier. The stale-503-not-debited fixture is present.

F. Recover + redaction: FAIL (coverage) — recover wraps the full `Handler()` stack including OPTIONS and 405 paths, strips `Authorization` / `Cookie` / `X-Api-Key`, logs only event/path/method/panic type at error level, and keeps stack output on Debug. HEAD added `RecoverForTest` and a real-panic fixture, but the panic-log sweep checks only the raw Authorization token and panic-string secret; it does not explicitly check `token_hash`, random-token substring, `Cookie`, `X-Api-Key`, or trace-span redaction.

G. Surface attack tests: PASS — implementation suppresses HEAD body bytes in success/error writers, suppresses `X-Stats-Generated-At` on 304, exact-matches `/v1/stats/{overview,leaderboard,health}`, and returns 405 with `Allow: GET, HEAD, OPTIONS`. Tests now include partner HEAD header/body parity and PUT/DELETE/PATCH 405 coverage. Error envelopes are generic and do not include SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

H. Step 4 boundary: PASS — Step 3 owns no partner-key CLI issuance/rotation/revocation surface, no nginx config, and no Prometheus metric-label authoring. Step 4-only content remains in spec/audit prompt material or comments, not executable Step 3 surface.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:872`
   - Evidence: HEAD narrows the round-5 coverage blocker but does not close it. `TestAC18_TimingEquivalenceRows5_6_7` still uses `const N = 30` samples per row at `handlers_integration_test.go:906`, below the BUILD-required 100+ requests per row, and does not include row 3 absent/malformed-Origin same-work timing. `TestPartnerProjectionNeverACAOStar` drives only one matched-Origin partner projection at `handlers_integration_test.go:983`, not all seven §5.7 rows. `TestAC11_RealPanicInjected` at `handlers_integration_test.go:1051` proves recover and omits two secret strings, but does not sweep `token_hash`, random-token substring, `Cookie`, `X-Api-Key`, or trace spans. A high-volume valid partner-key refund test above 300 requests is still absent.
   - Why: Step 3 is the first public partner-key attack surface. These fixtures are the regression locks for the controls that prevent timing oracle, CORS exposure, valid-key double-throttling, panic/trace token leaks, and browser-readable keyed rejection drift. The round-5 commit materially improved coverage with real panic, partner HEAD parity, and trusted/untrusted XFF, but the lock-pinned security matrix is still partial.
   - Fix: Add Step 3 tests for AC-18 rows 5/6/7 with 100+ requests per row at <=270 rpm plus row 3 absent/malformed-Origin same-work coverage; all seven §5.7 CORS rows including active-key-origin preflight union, rejected keyed 401 omitting ACAO, server-to-server empty-allowlist ACAO omission, sibling-subdomain exact-match rejection, and RFC 6454 malformed-Origin handling; valid partner-key auth-failure refund at a volume above 300 but below partner `rate_limit_rpm`; and AC-15 panic/trace redaction checks for raw token, `token_hash`, random substring, `Cookie`, and `X-Api-Key`.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/middleware.go:127` adds a focused `RecoverForTest` seam wrapping the same redaction + recover chain, allowing the round-6 real panic fixture without exposing production hooks in the mux.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1051` now drives a real panic, verifies the 500 `internal` envelope, checks panic-log omission of the raw bearer and panic-string secret, and proves the handler chain survives a second request.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1135` adds partner HEAD parity, including empty body and `Vary: Authorization`.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1232` adds trusted/untrusted XFF coverage; untrusted peers ignore spoofed XFF, while trusted proxy peers parse rotated client IPs.
- `phase4-coordinator/internal/stats/mux.go:202` refunds the success bucket on `rec.status == 0`, covering panic-before-write by implementation.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56` allowlists dynamic SQL table/order identifiers through validated `window` and `sort`, preventing user-controlled SQL identifier injection.
- `phase4-coordinator/internal/stats/origin.go:28` applies lowercase scheme/host, IDN-to-Punycode, default-port stripping, and malformed path/query/fragment handling.

## Positive Security Observations
- Request-path DB access remains isolated to `stats_reader`; rollup/admin pools are not exposed to public handlers.
- Raw bearer material is parsed once, stored only in request context under an unexported key, hashed by the auth dispatcher, and not serialized or logged by Step 3 code.
- The keyed auth dispatcher preserves the important timing ordering by computing SHA-256 and performing the `partner_keys` lookup before revocation or Origin decisions.
- Partner-key projection CORS omits `ACAO: *`; server-to-server partner responses omit ACAO when Origin is absent by implementation.
- Error envelopes use a closed code vocabulary and generic messages without SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.
- HEAD and 304 behavior are now pinned for the keyed surface: partner HEAD has zero body bytes and header parity; 304 omits `X-Stats-Generated-At`.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 7

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
