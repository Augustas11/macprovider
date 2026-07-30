# SPEC-017 IMPL Step 3 — Architecture Audit Round 5

Branch: `impl/spec-017-step-1`
HEAD audited: `220181a48e7b8bdca705318207d6d5ff514fba87` (`impl(017): Step 3 — round-4 audit fixes (ARCH 1M + SECURITY 1M + test coverage)`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r3-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r4-audit.md`

Verdict: READY TO LOCK —
0 CRITICAL + 0 HIGH + 0 MEDIUM + 1 LOW + 13 INFO

## Validation evidence
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/` — scoped Step 3 delta to `.golangci.yml`, `cmd/coordinator/main.go`, `go.mod`, `internal/stats/{auth,cors,envelope,etag,handlers,health_status,middleware,mux,origin,ratelimit}.go`, `internal/stats/store/*`, and Step 3 tests.
- `go build ./...` from `phase4-coordinator/` — PASS.
- `go test ./internal/stats/...` — PASS: `internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no tests.
- `go test -tags=integration -c ./internal/stats` — PASS compile smoke.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` — PASS against the amended allowlist: standard library, `internal/stats/store`, `github.com/rs/zerolog`, and the approved `golang.org/x/net/idna`; no forbidden internal imports were present.
- `gofmt -l ./internal/stats` — PASS, no output.
- `git diff --check origin/main...HEAD` — FAIL on pre-existing audit markdown trailing whitespace under prior `specs/SPEC-017-IMPL-STEP_2-*` and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no inspected phase4 Step 3 code whitespace errors were reported.
- `git diff --check bd68a0a..HEAD -- phase4-coordinator/` — PASS, no output.

## Category Verdicts
A. Endpoint + projection scope vs Step 4 boundary: PASS — Step 3 stays inside handlers, middleware, store reads, CORS, auth, in-process rate limits, redaction, recover, and mux wiring; no CLI, nginx, or Prometheus-label surface is implemented here.
B. Middleware stack ordering: PASS — `Handler()` wraps redaction-context → recover → access-log, then `dispatch` applies the leaderboard-only auth-failure reserve, auth dispatcher, success bucket, and handler in the pinned order.
C. §5.4.3 partner-key authn flow: PASS — keyed leaderboard requests hash and SELECT before Origin branching, malformed/present Authorization remains 401, no token-prefix early return is present, and v0.1 does not touch `last_used_at`.
D. CORS per §5.7: PASS — preflight is key-agnostic, returns 204/max-age 60 in the default/tested path, unions static and active key origins, and partner projection responses never emit `ACAO: *`.
E. Header surface: PASS — Cache-Control/Vary rows match projection, auth-failed 401 keeps public Vary, non-304 responses carry `X-Stats-Generated-At`, and 304 emits only ETag/Cache-Control/Vary.
F. Endpoint contract: PASS — overview, leaderboard, and health shapes align with §5.1-§5.3, including required `meta.rewards_populated`, public totals suppression, partner-only exact fields, config-driven `partial_history_since`, and the 7-component health map.
G. 503 + rate-limit semantics: PASS — overview stale probes run before success debit, handler non-2xx responses refund the success bucket, 429s include `Retry-After`, and rate-limit keys include the endpoint dimension.
H. Failure modes + main.go integration: PASS with LOW test-evidence gap — runtime wiring uses `stats_reader`, explicit HEAD/405 handling, and shared config injection; the AC-11 test does not inject a real panic even though the recover/refund code path exists.

## Findings
### CRITICAL
- None.

### HIGH
- None.

### MEDIUM
- None.

### LOW
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:803`
   - Evidence: the AC-11 test comment says an injected panic "MUST" return 500 and avoid success-bucket debit, but the test body explicitly uses a malformed leaderboard query as a representative 400 path because it "can't easily inject a panic" (`handlers_integration_test.go:803-813`). Runtime code does have the relevant paths: `recoverMiddleware` catches panics and writes the §5.9 `internal` envelope (`middleware.go:85-124`), and the mux refunds `rec.status == 0` as the pre-write panic path (`mux.go:193-208`).
   - Why: BUILD Step 3 AC-11 asks for an injected-panic verification. The architecture invariant is implemented, so this is not a lock blocker, but the test evidence is weaker than the prompt's stated AC-11 shape.
   - Fix: add a narrow test seam that mounts a panic handler behind the same redaction/recover/mux refund stack, or expose a test-only handler hook, then assert 500 `internal`, redacted panic log, `/healthz` survival if applicable, and no success-bucket debit.

### INFO
- `phase4-coordinator/internal/stats/origin.go:7` plus `.golangci.yml:42-57` close r4 MEDIUM 1: `golang.org/x/net/idna` is now explicitly approved for RFC 6454 IDN-to-Punycode Origin normalization, and the required `go list` validation contains no forbidden internal imports.
- `phase4-coordinator/internal/stats/mux.go:53-59` preserves the outer middleware order redaction-context → recover → access-log.
- `phase4-coordinator/internal/stats/mux.go:90-145` scopes auth-failure and §5.4.3 dispatch to `/leaderboard`; `/overview` and `/health` synthesize public auth results and ignore irrelevant Authorization.
- `phase4-coordinator/internal/stats/auth.go:162-165` performs `sha256` + `LookupPartnerKeyByHash` before the allowlist branch at `auth.go:197-212`, preserving row 5/6/7 timing shape.
- `phase4-coordinator/internal/stats/cors.go:51-71` returns preflight 204 with `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`, and the default/tested `Access-Control-Max-Age: 60`.
- `phase4-coordinator/internal/stats/cors.go:74-96` plus `store/store.go:48-89` keep the global preflight allowlist as static origins union active `partner_keys.allowed_origins`.
- `phase4-coordinator/internal/stats/handlers.go:397-401` reads `stats_rewards_populated`; no request-path query against `provider_rewards_ledger` was found in the handler/store path.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56-68` reads `stats_leaderboard_*` and left-joins `provider_visibility`; it does not branch off `provider_visibility_audit` or ad-hoc OLTP sums.
- `phase4-coordinator/internal/stats/handlers.go:495-499` and `handlers.go:541-567` keep `partial_history_since` config-driven and limited to Path A, 30d/all, and the still-short window period.
- `phase4-coordinator/internal/stats/handlers.go:589-601` locks the health component map to `overview`, `timeseries_rpm`, `timeseries_tpm`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, and `leaderboard_all`.
- `phase4-coordinator/internal/stats/envelope.go:9-18` keeps the §5.9 error code vocabulary closed to the six locked codes.
- `phase4-coordinator/internal/stats/handlers.go:679-708` computes ETag from the marshaled body, emits `X-Stats-Generated-At` on non-304, and suppresses the body for HEAD.
- `phase4-coordinator/cmd/coordinator/main.go:493-505` mounts the stats mux through `statsstore.New(statsPools.Reader)` and injects `BackfillMode`, `PartialHistorySince`, CORS, trusted proxies, and logger from coordinator config.

## Round-(M-1) Closure Checks
- r4 MEDIUM 1 (IDNA import outside prompt allowlist): closed. Evidence: the round-5 operator prompt's validation allowlist explicitly includes `golang.org/x/net/idna` as an approved Step 3 dependency for RFC 6454 §5.7 Origin normalization, `.golangci.yml:42-57` records the same approval, `origin.go:7` is the sole import, and the required `go list` validation now passes with no forbidden internal imports.

## Final Verdict
READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 13 INFO
