# SPEC-017 IMPL Step 3 — Security Audit Round 3

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `78466816141d9c3b773f2bc43c927374e6d83432` (`impl(017): Step 3 — round-2 audit fixes (1C + 6H + 3M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-security-r2-audit.md`
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, and rate-limit reserve-then-refund.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`, `specs/SPEC-017-IMPL-STEP_3-security-r2-audit.md`.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `78466816141d9c3b773f2bc43c927374e6d83432`, the round-2 Step 3 fix commit. Changed paths in this commit include `phase4-coordinator/internal/stats/{envelope.go,handlers.go,handlers_integration_test.go,mux.go,store/health.go}`, `.golangci.yml`, and prior round audit files.
- `git diff --name-only bd68a0a..HEAD` — PASS; Step 3 diff includes stats handlers/middleware/store/tests, coordinator mux wiring, stats module support, audit prompts, and r1/r2 audit artifacts.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` — PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` — PASS with scope note; handler-package log call sites are recover/access middleware only, with rollup logs outside this Step 3 request-path lens. No raw `Authorization` print/trace call site was found.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` — INFO deviation; no matches. The dispatcher uses `sha256.Sum256([]byte(bearer))` plus `SELECT ... WHERE token_hash = $1`; no in-process token-derived equality comparison was found.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` — PASS.
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` — PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` — PASS; no output.
- Additional coverage sweep: `rg -n "Test.*(Timing|timing|AC18|AC-18|Decision|decision|CORS|Origin|XFF|Forwarded|Trusted|stale|debited|debit|valid partner|refund|601st|301st|subdomain|evil\.streamvc|portal\.streamvc|stats_handler_panic|panic|trace|token_hash|random|Cookie|X-Api-Key)" phase4-coordinator/internal/stats -g '*_test.go'` — FAIL coverage; HEAD added AC-22 invalid-bearer cap, absent-Authorization scoping, AC-15 structured-log secret sweep, partial-history gating, and partner projection tests, but still lacks the fixtures listed in MEDIUM 1.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go` mounts `/v1/stats/` with `statsstore.New(statsPools.Reader)` only. Request-path store code issues SELECTs against stats tables, `provider_visibility`, and `partner_keys`; no handler path selects `ledger_*`, `provider_tokens`, `provider_rewards_ledger`, or `provider_visibility_audit`, and no rollup/admin pool is injected into `stats.NewMux`.

B. Token handling: PASS — `redactionContextMiddleware` stores the parsed bearer under unexported `authKey`, replaces `Authorization` with `REDACTED`, and strips `Cookie` plus `X-Api-Key`; `recoverMiddleware` repeats the strip. `dispatchAuth` hashes raw bearer UTF-8 bytes with SHA-256 and passes only the hash to `LookupPartnerKeyByHash`. No raw token, token hash, prefix, or label response/log/trace/metric projection was found in the Step 3 handler path.

C. Timing equivalence: FAIL (coverage) — implementation ordering is correct by inspection: rows 3/5/6/7 run `sha256 + SELECT by token_hash` before row presence, revocation, or Origin allowlist branching. However, the required AC-18 sustained-rate timing fixture for rows 5/6/7, plus row 3 same-work coverage, is still absent.

D. CORS + Origin: FAIL (coverage) — implementation normalizes Origin per RFC 6454, preflight is key-agnostic with max-age default 60 and clamp 300, rejected keyed 401s omit ACAO, and partner projection never takes the public `ACAO: *` branch. The full §5.7 seven-row CORS matrix, sibling-subdomain exact-match reject, and malformed-Origin branch fixtures are still absent.

E. Rate-limit security: FAIL (coverage) — implementation reserves auth-failure before auth dispatch, refunds on auth success before later error paths, ignores XFF unless the immediate peer is trusted, and refunds post-auth success buckets on non-2xx responses. Tests now cover the invalid-bearer 300 cap and absent-Authorization scoping, but still do not cover trusted/untrusted XFF, valid partner-key auth-failure refund, or stale-503-not-debited accounting.

F. Recover + redaction: FAIL (coverage) — recover wraps the entire mux returned by `Handler()` including OPTIONS and 405 paths, strips `Authorization` / `Cookie` / `X-Api-Key`, and logs only event/path/method/panic type at error level. HEAD added a structured-log secret sweep, but panic-log and trace-span redaction sweeps for raw token, `token_hash`, and random-token substring are still absent.

G. Surface attack tests: PASS with coverage caveat — HEAD bodies are suppressed by `writeJSON` / `writeError`, 304 suppresses `X-Stats-Generated-At`, strict endpoint matching rejects suffix paths, and 405 uses `Allow: GET, HEAD, OPTIONS`. Tests cover anonymous HEAD and 304; partner-key HEAD and all mutating verbs beyond POST are not separately pinned and are included in MEDIUM 1's fixture gap.

H. Step 4 boundary: PASS — no partner-key CLI issuance/rotation/revocation surface, nginx config, or Prometheus metric-label authoring landed in Step 3. Step 4-only references remain comments/spec prompt material.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:438`
   - Evidence: the round-2 fix added `TestAC22_AuthFailureLimiter`, `TestAuthFailureLimiterIgnoresAbsentAuth`, `TestAC15_RedactionSweep`, `TestPartialHistorySinceBackfillModeGate`, and `TestAC6_PartnerProjection`. A targeted grep across `internal/stats` tests still found no AC-18 timing test, no full §5.7 seven-row CORS decision table, no sibling-subdomain reject fixture, no trusted/untrusted `X-Forwarded-For` split, no valid partner-key auth-failure refund test, no stale-503-not-debited success-bucket test, no panic-log / trace-span redaction sweep, and no partner-key HEAD body fixture.
   - Why: Step 3 is the first public partner-key attack surface. The implementation looks correct by inspection, but the remaining missing fixtures are exactly the regression locks for timing oracle, CORS exposure, spoofed-XFF rate-limit bypass, valid-key double-throttling, outage-induced quota burn, and panic/trace token leak risks. The prior SECURITY r2 blocker was broader than the subset fixed by HEAD.
   - Fix: Add Step 3 tests for AC-18 rows 5/6/7 at a rate below the 300 rpm auth-failure cap, row 3 same-work path, all seven §5.7 CORS rows including partner projection never `ACAO: *` and rejected keyed 401 omitting ACAO, sibling-subdomain exact-match rejection, trusted/untrusted XFF behavior, valid partner-key auth-failure refund, stale 503 not debiting success buckets, panic-log and trace-span redaction for raw token / `token_hash` / random substring / `Cookie` / `X-Api-Key`, and partner-key HEAD body length zero.

### LOW
None.

### INFO
- `phase4-coordinator/internal/stats/mux.go:134` refunds the auth-failure reservation immediately after auth success, before freshness, success-rate-limit, or handler error paths.
- `phase4-coordinator/internal/stats/handlers.go:375` uses `stats_components_health.leaderboard_<window>.generated_at` as the snapshot timestamp for empty leaderboard pages.
- `phase4-coordinator/internal/stats/envelope.go:55` gives non-304 error responses endpoint-appropriate Cache-Control / Vary headers while keeping generic error envelopes.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:443` adds invalid-bearer auth-failure cap coverage; `:469` adds absent-Authorization scoping; `:556` adds structured-log redaction for Authorization / Cookie / X-Api-Key.

## Positive Security Observations
- Request-path DB access remains isolated to the `stats_reader` store injected in `cmd/coordinator/main.go`; rollup/admin pools are not exposed to handlers.
- Raw bearer material is parsed once, stashed only in request context under an unexported key, hashed by the auth dispatcher, and not serialized or logged.
- The auth dispatcher preserves the important timing ordering: keyed requests compute SHA-256 and perform the `partner_keys` lookup before revocation or Origin-allowlist decisions.
- Partner-key success CORS omits `ACAO: *`; rejected keyed 401s omit ACAO entirely.
- Error envelopes are closed-vocabulary and do not include SQL errors, DSN substrings, stack frames, hostnames, internal IPs, raw tokens, or token hashes.

## Final Verdict
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 4

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
