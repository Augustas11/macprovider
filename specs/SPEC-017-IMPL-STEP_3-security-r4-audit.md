# SPEC-017 IMPL Step 3 — Security Audit Round 4

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `96323866cca0fe1f387290b5c82c8a743632763e` (`impl(017): Step 3 — round-3 audit fixes (ARCH 1C+1H + CODE 2H)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r3-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, and rate-limit reserve-then-refund.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r2-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r3-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `96323866cca0fe1f387290b5c82c8a743632763e`. This round-3 fix commit changes `phase4-coordinator/internal/stats/{auth.go,cors.go,envelope.go,mux.go,store/store.go}` plus prior ARCH/CODE/SECURITY r3 audit files.
- `git diff --name-only bd68a0a..HEAD` — PASS; Step 3 diff includes coordinator mux wiring, stats handler/middleware/store/test files, stats module support, audit prompts, and prior round audit artifacts.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` — PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` — PASS with scope note; request-path log references are recover/access middleware comments and code only. Rollup logs/tests are outside this Step 3 request-path lens. No raw `Authorization` print/trace call site was found.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` — INFO deviation; no matches. Code inspection found no in-process secret-derived token equality comparison. The dispatcher uses `sha256.Sum256([]byte(bearer))` plus `SELECT ... WHERE token_hash = $1`; the prior no-op compare was intentionally removed.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` — PASS:
  - `internal/stats`
  - `internal/stats/migrations`
  - `internal/stats/rollup`
  - `internal/stats/store` (`[no test files]`)
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` — PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` — PASS; no output.
- Additional coverage sweep: `rg -n "AC-18|AC18|timing|DecisionTable|7-row|allowed_origins|Access-Control-Allow-Origin|X-Forwarded-For|clientIP|trusted|authfail|auth-failure|refund|stale.*debit|stats_handler_panic|trace|token_hash|random portion|random-substring|evil\.streamvc|portal\.streamvc|DELETE|PATCH|PUT" phase4-coordinator/internal/stats -g '*_test.go'` — FAIL coverage; current Step 3 tests still do not include the required AC-18 timing fixture, full §5.7 CORS matrix, sibling-subdomain reject, trusted/untrusted XFF split, valid partner-key auth-failure refund, stale-503-not-debited accounting, panic-log/trace-span redaction sweep, or non-POST mutating verb matrix.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)` only. Request-path store code reads `partner_keys`, stats tables, `stats_rewards_populated`, and `provider_visibility`; no handler/store path imports `internal/stats/migrations`, receives an admin/rollup pool, or selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS — `redactionContextMiddleware` parses the bearer once, stores it under unexported `authKey`, replaces `Authorization` with `REDACTED`, and also redacts `Cookie` plus `X-Api-Key`. `recoverMiddleware` repeats the strip. `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash`. No raw token, token hash, prefix, or label response/log/trace/metric projection was found in the Step 3 handler path.

C. Timing equivalence: FAIL (coverage) — implementation ordering is correct by inspection: keyed `/leaderboard` requests run `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching; rows 3/5/6/7 share that work. However, the required AC-18 sustained-rate timing fixture for rows 5/6/7, plus row 3 same-work/malformed-Origin coverage, is still absent.

D. CORS + Origin: FAIL (coverage) — implementation normalizes Origin per RFC 6454, preflight is key-agnostic with max-age default 60 and cap 300, partner projection never emits `ACAO: *`, and rejected keyed 401s omit ACAO. HEAD now unions configured origins with active `partner_keys.allowed_origins` for preflight. Tests still do not drive the full §5.7 seven-row matrix, active-key-origin preflight union, sibling-subdomain exact-match reject, malformed-Origin branch, or partner-projection never-`*` assertion.

E. Rate-limit security: FAIL — auth-failure limiting is scoped to `/leaderboard`, runs before auth dispatch, reserves only after `allow` succeeds, refunds on valid auth success, keys by trusted-proxy-aware client IP, and ignores spoofed XFF when no trusted proxy is configured. However, the post-auth success-bucket refund misses panic-before-write 500s (MEDIUM 1), and the tests still do not cover trusted/untrusted XFF, valid partner-key auth-failure refund, stale-503-not-debited accounting, or SQL lookup counting for AC-22.

F. Recover + redaction: FAIL (coverage) — recover wraps the full `Handler()` stack including OPTIONS and 405 paths, strips `Authorization` / `Cookie` / `X-Api-Key`, logs only event/path/method/panic type at error level, and keeps the stack on a Debug line. The current AC-15 test sends a non-panic request and only asserts an empty structured-log buffer does not contain secrets; it does not exercise panic-log redaction, trace-span redaction, `token_hash`, or random-token substring checks.

G. Surface attack tests: FAIL (coverage) — implementation suppresses HEAD body bytes in `writeJSON` / `writeError`, suppresses `X-Stats-Generated-At` on 304, uses exact endpoint matching, and returns 405 with `Allow: GET, HEAD, OPTIONS`. Tests cover anonymous HEAD and POST 405, but still lack partner-key HEAD body/header parity and PUT/DELETE/PATCH 405 fixtures. Error envelopes are generic and do not include SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

H. Step 4 boundary: PASS — Step 3 owns no partner-key CLI issuance/rotation/revocation surface, no nginx config, and no Prometheus metric-label authoring. Step 4-only content remains in spec/audit prompt material or comments, not executable Step 3 surface.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/mux.go:193`
   - Evidence: the post-auth success-bucket defer refunds only when `rec.status != 0 && (rec.status < 200 || rec.status >= 300) && rec.status != http.StatusNotModified`. If a handler panics after the public/partner success bucket is reserved but before writing any status, `rec.status` remains `0`, the dispatch defer does not refund, and only the outer recover middleware later emits the 500 at `phase4-coordinator/internal/stats/middleware.go:120`.
   - Why: BUILD Step 3 requires post-auth success accounting to track successful 2xx only; 500s must not consume public or partner quota. A panic before first write is exactly the recover path AC-11 is meant to pin, and it currently leaves the success bucket charged despite returning `500 internal`. During a panic-triggering regression, clients can be pushed toward 429 by failed requests.
   - Fix: Treat `rec.status == 0` during defer unwinding as a non-success and refund the success bucket. Add an injected-panic AC-11 test that sends public and partner-key requests through the full mux, asserts the 500 envelope/recover log redaction, and asserts the next 60 public or 600 partner successful requests are not reduced by the panic.

2. `phase4-coordinator/internal/stats/handlers_integration_test.go:443`
   - Evidence: current Step 3 integration tests cover basic invalid Bearer, generic preflight, stale overview 503, POST 405, anonymous HEAD body suppression, public earnings-total omission, 304, health degradation, AC-22 invalid-bearer cap, absent-Authorization auth-failure scoping, partial-history gating, a non-panic structured-log redaction check, and a basic partner projection. Targeted greps found no AC-18 timing test, no full §5.7 seven-row CORS decision table, no active partner-origin preflight union fixture, no sibling-subdomain reject fixture, no trusted/untrusted `X-Forwarded-For` split, no valid partner-key auth-failure refund test, no stale-503-not-debited success-bucket test, no panic-log / trace-span redaction sweep, no partner-key HEAD fixture, and no PUT/DELETE/PATCH 405 matrix.
   - Why: Step 3 is the first public partner-key attack surface. The untested controls are the regression locks for timing oracle, CORS exposure, spoofed-XFF rate-limit bypass, valid-key double-throttling, outage-induced quota burn, panic/trace token leak, and method-surface oddities. Round 3 already carried this as one MEDIUM coverage blocker; HEAD changed code but did not close the coverage gap.
   - Fix: Add Step 3 tests for AC-18 rows 5/6/7 at a rate below the 300 rpm auth-failure cap and row 3 same-work/malformed-Origin behavior; all seven §5.7 CORS rows including active-key-origin preflight union, partner projection never `ACAO: *`, rejected keyed 401 omitting ACAO, sibling-subdomain exact-match rejection, and RFC 6454 malformed-Origin handling; trusted/untrusted XFF behavior; valid partner-key auth-failure refund; stale 503 not debiting success buckets; panic-log and trace-span redaction for raw token / `token_hash` / random substring / `Cookie` / `X-Api-Key`; partner-key HEAD body length zero; and PUT/DELETE/PATCH 405.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/mux.go:90` correctly scopes partner-key auth and auth-failure limiting to `/v1/stats/leaderboard`; `/overview` and `/health` ignore `Authorization` and retain public headers.
- `phase4-coordinator/internal/stats/cors.go:51` now includes active `partner_keys.allowed_origins` in the preflight global allowlist union, addressing the round-3 ARCH H1 issue by inspection.
- `phase4-coordinator/internal/stats/mux.go:96` registers auth-failure refunds only after `allow()` succeeds, so 429 rejection no longer decrements an already-full bucket.
- `phase4-coordinator/internal/stats/envelope.go:100` tags post-auth partner errors with partner Cache-Control/Vary while leaving auth-failed 401s on the public Vary row.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56` continues to allowlist dynamic SQL table/order names through validated `window` and `sort`, preventing user-controlled SQL identifier injection.

## Positive Security Observations
- Request-path DB access remains isolated to `stats_reader`; rollup/admin pools are not exposed to the public handler stack.
- Raw bearer material is parsed once, kept only in request context under an unexported key, hashed with SHA-256, and not serialized or logged.
- The keyed auth dispatcher preserves the important timing ordering by computing hash and selecting by `token_hash` before revocation or Origin decisions.
- Partner-key projection CORS omits `ACAO: *`; server-to-server partner responses omit ACAO when Origin is absent.
- Error envelopes use a closed code vocabulary and generic messages without SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 2
LOW: 0
INFO: 5

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
