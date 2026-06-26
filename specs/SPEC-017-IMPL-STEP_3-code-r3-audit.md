# SPEC-017 IMPL Step 3 — Code Audit Round 3

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `7846681` (`impl(017): Step 3 — round-2 audit fixes (1C + 6H + 3M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r2-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — overview now has the 14-field network object and pointer-backed 30-point timeseries nulls; leaderboard has stable public/partner projections, required `meta.rewards_populated`, `partial_history_since` gated on partial backfill + 30d/all only, and health derives the seven-key component map at request time.
B. Header correctness: FAIL — success and 304 paths are mostly correct, but partner-authenticated error responses still receive public leaderboard Cache-Control/Vary.
C. Authn flow + crypto: PASS — auth hashes `sha256([]byte(bearer))`, SELECTs by `token_hash` before Origin branching, applies RFC 6454 normalization, and has no in-process `==` / `bytes.Equal` comparison of token-derived bytes.
D. Rate-limit buckets: FAIL — bucket keys include endpoint dimensions and auth-failure reserve/refund is scoped correctly, but denied public/partner success-bucket requests refund a slot they never reserved.
E. Error envelope: PASS — response bodies use only the six §5.9 codes and 304 is empty with only ETag/Cache-Control/Vary.
F. Store correctness: PASS — request-path store is SELECT-only through `stats_reader`, reads `stats_rewards_populated`, avoids forbidden OLTP tables, and LEFT JOINs `provider_visibility`.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS allowlist is explicit, JSON/error writers suppress HEAD bodies, and 405 sets `Allow: GET, HEAD, OPTIONS`.
H. Tests: FAIL — several Step 3-owned ACs and adversarial assertions remain unpinned, including tests that would catch the success-bucket refund bug.

## Findings
### CRITICAL
None.

### HIGH
1. `phase4-coordinator/internal/stats/mux.go:177`
   - Evidence: the success-bucket refund defer is installed before the code knows whether `allow` actually reserved a slot. `limiter.allow` returns `false` without incrementing when the bucket is full (`phase4-coordinator/internal/stats/ratelimit.go:67`), but the deferred refund still runs after `writeError` records a 429 (`phase4-coordinator/internal/stats/mux.go:191`) and decrements the existing bucket count (`phase4-coordinator/internal/stats/ratelimit.go:87`). Same pattern exists for the public bucket at `phase4-coordinator/internal/stats/mux.go:185`.
   - Why: after a public client reaches 60/min, request 61 returns 429 and refunds the count from 60 to 59; request 62 is then allowed. Partner keys have the same 601st/602nd alternation. This violates the hard per-minute limits and is wrong on the wire.
   - Fix: only register/run the refund path after `allowed == true`, or guard each defer with `if allowed && rec.status != 0 && ...`.

2. `phase4-coordinator/internal/stats/envelope.go:94`
   - Evidence: `writeError` always derives leaderboard error headers from `errorHeadersForRequest`, which returns public leaderboard headers: `Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=120` and `Vary: Accept-Encoding, Origin`. Partner-authenticated error paths, including partner success-bucket 429 from `phase4-coordinator/internal/stats/mux.go:170` and stale/internal handler errors after successful auth, therefore do not receive the locked partner row (`private, max-age=30, s-maxage=30`; `Vary: Accept-Encoding, Origin, Authorization`).
   - Why: the Step 3 header contract requires exact Cache-Control/Vary per the four endpoint/projection rows. The build prompt only special-cases auth-failed 401 into public Vary; post-auth partner errors are part of the partner request shape and must not be cacheable as public leaderboard responses.
   - Fix: pass the authenticated projection/header policy into the error writer for post-auth paths, while keeping auth-failed 401 on the public no-key policy.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:125`
   - Evidence: current Step 3 handler integration coverage includes AC-1, AC-2, AC-3, AC-6, AC-7 down-only, AC-12, AC-13, AC-14, AC-15 header redaction, AC-21, and AC-22 invalid/absent auth-failure checks. It does not pin AC-4 bucketed public `exact_earnings: null`, AC-5 exact public `exact_earnings`, AC-11 panic recovery, AC-18 rows 5/6/7 timing, partner HEAD identical headers, CORS 7-row behavior, RFC 6454 GET decision-table cases, valid-partner-not-capped-at-300, partner error headers, or the required 100 stale + 60 fresh not-debited scenario. The existing absent-Authorization limiter test is behind the `integration` build tag and the required validation command only compiles integration tests, so the HIGH refund bug above is not caught by the default test run.
   - Why: missing tests are MEDIUM under the audit prompt, and these gaps leave wrong-on-wire rate-limit and header behavior unpinned.
   - Fix: add explicit pass/fail assertions for each Step 3-owned AC/adversarial case, especially success-bucket over-limit stability, partner projection error headers, AC-18 timing below the auth-failure threshold, and the stale-503-not-debited sequence.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; prior CODE rounds `specs/SPEC-017-IMPL-STEP_3-code-r1-audit.md` and `specs/SPEC-017-IMPL-STEP_3-code-r2-audit.md`.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2 audit markdown files and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no Step 3 Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go`, comments, and the lint test that asserts the ban; normal lint passes.
- Store wiring evidence: `phase4-coordinator/cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)`.
- Auth evidence: `phase4-coordinator/internal/stats/auth.go:149` computes `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go`'s `sha256(token_utf8_bytes)` discipline.

## Final Verdict
Counts: 0 CRITICAL / 2 HIGH / 1 MEDIUM / 0 LOW / 10 INFO
Verdict: NOT READY TO LOCK
