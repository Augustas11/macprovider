# SPEC-017 IMPL Step 3 - Security Audit Round 8

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `2b2725655cd2521869e7e6d59fd2b3a8f5af6751` (`impl(017): Step 3 - round-7 test coverage (CODE M + SECURITY M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r7-audit.md`
Lens: SECURITY - role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 5.4, 5.6, 5.7, 6.1, 6.4, 6.6, 7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, rate-limit reserve-then-refund, and Step 3-owned test matrix.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md` through `specs/SPEC-017-IMPL-STEP_3-security-r7-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`. No repo-root `MEMORY.md` exists in this worktree.

## Validation Run
- `git show --name-only --format=fuller HEAD` - PASS; HEAD is `2b2725655cd2521869e7e6d59fd2b3a8f5af6751`. The round-7 coverage commit changes `phase4-coordinator/internal/stats/handlers_integration_test.go`, `phase4-coordinator/internal/stats/mux.go`, `phase4-coordinator/internal/stats/ratelimit.go`, `phase4-coordinator/internal/stats/store/store.go`, and prior r7 CODE/SECURITY audit files.
- `git diff --name-only bd68a0a..HEAD` - PASS; Step 3 diff includes `.golangci.yml`, coordinator mux wiring, stats handler/middleware/auth/CORS/rate-limit/store/test files, stats module support, Step 3 audit prompts, and prior Step 3 audit artifacts.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` - PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` - PASS with scope note; request-path log surfaces are recover/access middleware and tests. No raw `Authorization` print/trace call site was found. Rollup logs/tests are outside this Step 3 request-path lens.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` - INFO deviation; no matches. Code inspection found no in-process secret-derived equality comparison. The dispatcher hashes `[]byte(bearer)` with SHA-256 and performs `SELECT ... WHERE token_hash = $1`; timing equivalence is covered by shared hash+SELECT work plus AC-18 latency testing.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` - PASS:
  - `internal/stats`
  - `internal/stats/migrations`
  - `internal/stats/rollup`
  - `internal/stats/store` (`[no test files]`)
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` - PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` - PASS; no output.
- `git diff --check` - PASS; no whitespace errors in the audited worktree.

## Category Verdicts
A. Role + pool isolation: PASS - `cmd/coordinator/main.go:493` mounts `/v1/stats/` with `statsstore.New(statsPools.Reader)` only. Request-path store methods use SELECTs against stats tables, `stats_rewards_populated`, `provider_visibility`, and `partner_keys`; no handler/store path imports `internal/stats/migrations`, receives an admin/rollup pool, or selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`.

B. Token handling: PASS - `redactionContextMiddleware` parses the bearer once, stores it under unexported `authKey`, replaces `Authorization` with `REDACTED`, and strips `Cookie` plus `X-Api-Key` (`middleware.go:50`). `recoverMiddleware` repeats the strip (`middleware.go:85`). `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash` (`auth.go:164`, `store.go:117`). No raw token, token hash, prefix, or label response/log/trace/metric projection was found in Step 3 request-path code.

C. Timing equivalence: PASS - keyed `/leaderboard` requests perform `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching (`auth.go:162`). Row 3 and rows 5/6/7 share that work. `TestAC18_TimingEquivalenceRows5_6_7` now uses `const N = 100` with a 225ms cadence, keeping the sustained rate below the 300 rpm auth-failure cap (`handlers_integration_test.go:926`).

D. CORS + Origin: PASS - implementation normalizes Origin per RFC 6454 (`origin.go:28`), preflight is key-agnostic with default max-age 60 and cap 300 (`cors.go:51`), partner projection never emits `ACAO: *` (`cors.go:110`), and rejected keyed 401s omit ACAO (`mux.go:115`). Tests cover the 7-row CORS matrix (`handlers_integration_test.go:1351`), active-key preflight union (`handlers_integration_test.go:1455`), sibling-subdomain rejection (`handlers_integration_test.go:1560`), and the r7 server-to-server empty-allowlist row 4 (`handlers_integration_test.go:1583`).

E. Rate-limit security: PASS - auth-failure limiting is scoped to `/leaderboard`, reserves before auth dispatch, refunds on valid auth success, keys by trusted-proxy-aware client IP, and ignores spoofed XFF when no trusted proxy is configured (`mux.go:90`, `ratelimit.go:114`). Tests cover invalid-bearer pre-SELECT cap with `LookupHashCountForTest() <= 300` (`handlers_integration_test.go:444`), absent-Authorization scoping (`handlers_integration_test.go:490`), trusted/untrusted XFF (`handlers_integration_test.go:1280`), stale-503 not debiting success buckets (`handlers_integration_test.go:862`), and the r7 500-valid-partner auth-failure refund proof (`handlers_integration_test.go:1499`).

F. Recover + redaction: PASS - recover wraps the full `Handler()` stack including OPTIONS and 405 paths (`mux.go:53`), strips `Authorization` / `Cookie` / `X-Api-Key`, logs only event/path/method/panic type at error level, and keeps stack output on Debug (`middleware.go:85`). The panic-log fixture checks raw bearer, random substring, Cookie, X-Api-Key, synthetic token-hash value, and literal `token_hash` absence (`handlers_integration_test.go:1075`). `TestNoTraceImports` prevents trace/span surfaces from entering Step 3 without re-enforcing AC-15 (`handlers_integration_test.go:1642`).

G. Surface attack tests: PASS - implementation suppresses HEAD body bytes in success/error writers (`handlers.go:705`, `envelope.go:65`), suppresses `X-Stats-Generated-At` on 304 (`handlers.go:687`), exact-matches `/v1/stats/{overview,leaderboard,health}` (`handlers.go:726`), and returns 405 with `Allow: GET, HEAD, OPTIONS` (`mux.go:76`). Tests include partner HEAD header/body parity (`handlers_integration_test.go:1183`), 304 no-body/no-generated-at (`handlers_integration_test.go:345`), and PUT/DELETE/PATCH 405 coverage (`handlers_integration_test.go:1052`). Error envelopes are generic and do not include SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.

H. Step 4 boundary: PASS - Step 3 owns no partner-key CLI issuance/rotation/revocation surface, no nginx config, and no Prometheus metric-label authoring. Step 4-only content remains in spec/audit prompt material or comments, not executable Step 3 surface.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/store/store.go:117` increments `LookupHashCountForTest` before the partner-key SELECT, giving AC-22 a direct DB-load cap proof.
- `phase4-coordinator/internal/stats/mux.go:248` exposes a test-only auth-failure bucket count, and `handlers_integration_test.go:1551` proves 500 valid keyed requests leave zero leaked reservations.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1583` adds the locked section 5.7 row 4 server-to-server case: empty allowlist, no Origin, 200 partner projection, ACAO omitted, credentials omitted.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1129` adds literal token-hash value and `token_hash` field-name assertions to the panic-log redaction sweep.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:1642` adds a no-trace-import guard for Step 3.
- `phase4-coordinator/internal/stats/auth.go:164` uses `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go` token-hash derivation by raw UTF-8 bytes.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56` allowlists dynamic SQL table/order identifiers through validated `window` and `sort`, preventing user-controlled SQL identifier injection.
- `phase4-coordinator/internal/stats/origin.go:28` applies lowercase scheme/host, IDN-to-Punycode, default-port stripping, and malformed path/query/fragment handling.

## Positive Security Observations
- Request-path DB access remains isolated to `stats_reader`; rollup/admin pools are not exposed to public handlers.
- Raw bearer material is parsed once, stored only in request context under an unexported key, hashed by the auth dispatcher, and not serialized or logged by Step 3 code.
- The keyed auth dispatcher preserves timing ordering by computing SHA-256 and performing the `partner_keys` lookup before revocation or Origin decisions.
- Partner-key projection CORS omits `ACAO: *`; server-to-server partner responses omit ACAO and credentials when Origin is absent.
- Auth-failure limiter coverage now proves both sides of the reserve-then-refund contract: invalid bearer floods are capped before SELECT, and valid partner requests do not leak auth-failure reservations.
- Error envelopes use a closed code vocabulary and generic messages without SQL errors, DSNs, stack frames, env vars, hostnames, internal IPs, raw tokens, or token hashes.
- HEAD and 304 behavior are pinned for the keyed surface: partner HEAD has zero body bytes and header parity; 304 omits `X-Stats-Generated-At`.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 8

READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
