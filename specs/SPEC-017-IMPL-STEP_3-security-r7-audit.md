# SPEC-017 IMPL Step 3 — Security Audit Round 7

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `5fbf18e4ba64a5e7aa5dee1fc4fdfde43403f39d` (`impl(017): Step 3 — round-6 test coverage closure (final test batch)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r6-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, rate-limit reserve-then-refund, and Step 3-owned test matrix.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md` through `specs/SPEC-017-IMPL-STEP_3-security-r6-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`. No repo-root `MEMORY.md` exists in this worktree.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `5fbf18e4ba64a5e7aa5dee1fc4fdfde43403f39d`. The round-6 closure commit changes `phase4-coordinator/internal/stats/handlers_integration_test.go` plus the prior r6 CODE/SECURITY audit files.
- `git diff --name-only bd68a0a..HEAD` — PASS; Step 3 diff includes coordinator mux wiring, stats handler/middleware/auth/CORS/rate-limit/store/test files, module support, Step 3 audit prompts, and prior Step 3 audit artifacts.
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
- Additional r6-closure sweep: `rg -n "TestAC18|N =|TestSection_5_7_CORSMatrix|TestPreflightActiveKeyOriginUnion|TestValidPartnerKey500ReqNoAuthFailureCap|TestAC11_RealPanicInjected|token_hash|trace|span" phase4-coordinator/internal/stats` — FAIL coverage; HEAD adds the requested 100-sample AC-18 test, active-key preflight union test, 500-valid-key refund test, and a broader panic-redaction test, but the CORS matrix and AC-15 redaction sweep still have the lock-pinned gaps listed in MEDIUM 1.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go:493` mounts `/v1/stats/` with `statsstore.New(statsPools.Reader)` only. Request-path store methods read stats tables, `stats_rewards_populated`, `provider_visibility`, and `partner_keys`; no handler/store path imports `internal/stats/migrations`, receives an admin/rollup pool, or selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS — `redactionContextMiddleware` parses the bearer once, stores it under unexported `authKey`, replaces `Authorization` with `REDACTED`, and strips `Cookie` plus `X-Api-Key`. `recoverMiddleware` repeats the strip. `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash`. No raw token, token hash, prefix, or label response/log/trace/metric projection was found in Step 3 request-path code.

C. Timing equivalence: PASS — keyed `/leaderboard` requests perform `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching. `TestAC18_TimingEquivalenceRows5_6_7` now uses `const N = 100` with a 225ms cadence, keeping the sustained rate below the 300 rpm auth-failure cap.

D. CORS + Origin: FAIL (coverage) — implementation normalizes Origin per RFC 6454, preflight is key-agnostic with default max-age 60 and cap 300, partner projection never emits `ACAO: *`, active-key preflight union is covered, and rejected keyed 401s omit ACAO. However, the claimed §5.7 seven-row matrix still omits the empty-allowlist server-to-server partner projection row where Origin is absent and ACAO/Allow-Credentials must both be omitted.

E. Rate-limit security: PASS — auth-failure limiting is scoped to `/leaderboard`, reserves before auth dispatch, refunds on valid auth success, keys by trusted-proxy-aware client IP, and has trusted/untrusted XFF fixtures. HEAD adds a 500-request valid partner-key fixture proving the auth-failure 300 rpm tier does not cap valid partner traffic below the partner key's 600 rpm tier.

F. Recover + redaction: FAIL (coverage) — recover wraps the full `Handler()` stack including OPTIONS and 405 paths, strips `Authorization` / `Cookie` / `X-Api-Key`, logs only event/path/method/panic type at error level, and keeps stack output on Debug. The panic-log fixture is broader than r6, but it still does not assert the seeded token-hash-shaped value is absent and there is no Step 3 trace-span redaction fixture.

G. Surface attack tests: PASS — implementation suppresses HEAD body bytes in success/error writers, suppresses `X-Stats-Generated-At` on 304, exact-matches `/v1/stats/{overview,leaderboard,health}`, and returns 405 with `Allow: GET, HEAD, OPTIONS`. Tests include partner HEAD header/body parity and PUT/DELETE/PATCH 405 coverage. Error envelopes are generic and do not include SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

H. Step 4 boundary: PASS — Step 3 owns no partner-key CLI issuance/rotation/revocation surface, no nginx config, and no Prometheus metric-label authoring. Step 4-only content remains in spec/audit prompt material or comments, not executable Step 3 surface.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:1328`
   - Evidence: `TestSection_5_7_CORSMatrix` drives anonymous, empty-allowlist browser Origin, non-empty allowlist absent/match/reject, no-match, and revoked cases, but it does not drive the locked §5.7 empty-allowlist server-to-server row: valid partner key, `allowed_origins = '{}'`, Origin absent, 200 partner projection, `Access-Control-Allow-Origin` omitted, and `Access-Control-Allow-Credentials` omitted. Separately, `TestAC11_RealPanicInjected` seeds `rawTokenHash` at `handlers_integration_test.go:1075` and `X-Token-Hash` at `handlers_integration_test.go:1079`, but the leak list at `handlers_integration_test.go:1100` does not include `rawTokenHash`; `rg "trace|span|otel|OpenTelemetry" phase4-coordinator/internal/stats` finds no trace-span fixture, and `middleware.go:142` says trace/span instrumentation is a Step 4.C concern even though the Step 3 AC-15 share requires trace-span redaction confirmation.
   - Why: The lock target requires every category to produce evidence. Missing one §5.7 fixture is explicitly a MEDIUM defense-in-depth gap, and the Step 3 redaction lock must prove no raw token / `token_hash` / random substring across handler structured logs, panic logs, and trace spans. The implementation appears clean by inspection, but the regression locks still do not fully cover the public partner-key attack surface.
   - Fix: Add a §5.7 matrix case for empty-allowlist server-to-server partner projection with absent Origin and explicit ACAO/Allow-Credentials omission checks. Add `rawTokenHash` to the panic-log leak list, add a literal `token_hash` leak assertion where appropriate, and add a Step 3 trace/span redaction fixture or a narrow documented no-trace invariant test that fails if tracing is introduced without the same redaction guarantees.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/auth.go:164` uses `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go:128` token hash derivation.
- `phase4-coordinator/internal/stats/mux.go:96` reserves the auth-failure bucket before auth dispatch; `mux.go:124` refunds it on valid partner auth success.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:910` now uses 100 AC-18 timing samples per row at ~265 rpm.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1432` adds active-key preflight union coverage.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1476` adds the 500 valid partner-key refund proof.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1529` adds sibling-subdomain preflight rejection coverage.
- `phase4-coordinator/internal/stats/origin.go:28` applies lowercase scheme/host, IDN-to-Punycode, default-port stripping, and malformed path/query/fragment handling.

## Positive Security Observations
- Request-path DB access remains isolated to `stats_reader`; rollup/admin pools are not exposed to public handlers.
- Raw bearer material is parsed once, stored only in request context under an unexported key, hashed by the auth dispatcher, and not serialized or logged by Step 3 code.
- The keyed auth dispatcher preserves timing ordering by computing SHA-256 and performing the `partner_keys` lookup before revocation or Origin decisions.
- Partner-key projection CORS omits `ACAO: *`; server-to-server partner responses omit ACAO by implementation.
- Error envelopes use a closed code vocabulary and generic messages without SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.
- HEAD and 304 behavior remain pinned for the keyed surface: partner HEAD has zero body bytes and header parity; 304 omits `X-Stats-Generated-At`.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 7

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
