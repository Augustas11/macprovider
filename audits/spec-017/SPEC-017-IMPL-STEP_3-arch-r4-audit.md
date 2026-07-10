# SPEC-017 IMPL Step 3 — Architecture Audit Round 4

Branch: `impl/spec-017-step-1`
HEAD audited: `96323866cca0fe1f387290b5c82c8a743632763e` (`impl(017): Step 3 — round-3 audit fixes (ARCH 1C+1H + CODE 2H)`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r3-audit.md`

Verdict: NOT READY TO LOCK —
0 CRITICAL + 0 HIGH + 1 MEDIUM + 0 LOW + 10 INFO

## Validation evidence
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/` — scoped Step 3 delta to `.golangci.yml`, `cmd/coordinator/main.go`, `go.mod`, `internal/stats/{auth,cors,envelope,etag,handlers,health_status,middleware,mux,origin,ratelimit}.go`, `internal/stats/store/*`, and Step 3 tests.
- `go build ./...` from `phase4-coordinator/` — PASS.
- `go test ./internal/stats/...` — PASS: `internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no tests.
- `go test -tags=integration -c ./internal/stats` — PASS compile smoke.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` — FAIL against this audit prompt's explicit handler-package allowlist because `golang.org/x/net/idna` remains imported; no forbidden internal imports (`internal/ws`, `internal/explorer`, `internal/billing`, `internal/buyer`, `internal/session`) were present.
- `gofmt -l ./internal/stats` — PASS, no output.
- `git diff --check origin/main...HEAD` — FAIL on pre-existing audit markdown trailing whitespace under prior `specs/SPEC-017-IMPL-STEP_2-*` and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no inspected phase4 Step 3 code whitespace errors were reported.
- `git diff --check bd68a0a..HEAD -- phase4-coordinator/` — PASS, no output.

## Category Verdicts
A. Endpoint + projection scope vs Step 4 boundary: PASS — Step 3 remains scoped to handlers, middleware, store reads, CORS, auth, rate limits, redaction, and mux wiring; no partner-key CLI, nginx, or observability-label surface is implemented here.
B. Middleware stack ordering: PASS — redaction-context → recover → access-log wrapper order is preserved, and the inner leaderboard path applies auth-failure reservation, auth dispatch, success bucket, then handler; overview/health correctly bypass partner-key auth per §4.3.
C. §5.4.3 partner-key authn flow: PASS — keyed leaderboard requests hash+SELECT before origin branching, revoked/no-row/rejected-origin 401 paths share the same DB lookup shape, and no `last_used_at` write is present.
D. CORS per §5.7: PASS — preflight returns 204/max-age 60 and now unions static partner origins with active `partner_keys.allowed_origins`; partner projection never emits `ACAO: *`.
E. Header surface: PASS — success responses carry the locked Cache-Control/Vary rows, `X-Stats-Generated-At` on non-304, full-body SHA-256 ETags, and 304 carries only RFC 7232 headers.
F. Endpoint contract: PASS — overview, leaderboard, and health shapes align with §5.1-§5.3, including page-scoped public totals, partner-only exact fields, required `meta.rewards_populated`, 7 health components, and empty-leaderboard snapshot metadata.
G. 503 + rate-limit semantics: PASS — stale overview is pre-checked before success debit; leaderboard handler errors/stale responses refund the success bucket; auth-failure reservation is scoped to Authorization-present leaderboard traffic and refunded on valid partner success.
H. Failure modes + main.go integration: FAIL — `cmd/coordinator/main.go` mounts the same binary with `stats_reader`, but the handler package import graph still exceeds the operator-paste allowlist via `golang.org/x/net/idna`.

## Findings
### CRITICAL
- None.

### HIGH
- None.

### MEDIUM
1. `phase4-coordinator/internal/stats/origin.go:7`
   - Evidence: `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` still reports `golang.org/x/net/idna`, and `origin.go:7` imports it. `.golangci.yml:42-57` documents a local approval for RFC 6454 IDN-to-Punycode normalization, but this round's audit prompt still defines the handler-package validation allowlist as standard library, `internal/auth` for shared hash helpers only, `internal/config`, `internal/stats/store`, optional `internal/pool`, and `github.com/rs/zerolog`.
   - Why: this is the same round-1/2/3 ARCH MEDIUM import-boundary issue. The dependency is technically justified by SPEC §5.4.3 / §5.7 IDN normalization, but the controlling audit validation remains explicit and still fails; two conforming Step 3 sessions can still resolve this differently unless the controlling boundary is amended or the helper is moved behind an approved local surface.
   - Fix: either amend the controlling Step 3 dependency/import boundary to explicitly allow `golang.org/x/net/idna`, or move Origin normalization behind an approved local helper/package and update the allowlist/tests accordingly.

### LOW
- None.

### INFO
- `phase4-coordinator/internal/stats/mux.go:86-145` closes r3 CRITICAL 1 by applying the §5.4.3 auth dispatcher only to `endpoint == "leaderboard"`; `/overview` and `/health` synthesize a public auth result and ignore Authorization.
- `phase4-coordinator/internal/stats/cors.go:51-96` plus `store/store.go:48-89` close r3 HIGH 1 by unioning configured partner origins with active `partner_keys.allowed_origins` for key-agnostic preflight.
- `phase4-coordinator/internal/stats/mux.go:94-126` preserves the auth-failure reserve-then-refund shape: invalid/revoked/rejected keyed requests keep the 300 rpm debit, while valid partner successes refund before downstream errors.
- `phase4-coordinator/internal/stats/mux.go:147-157` keeps overview stale 503 before public success-bucket debit; `mux.go:193-200` refunds non-2xx/500/503 handler outcomes after the success bucket.
- `phase4-coordinator/internal/stats/envelope.go:96-116` now selects partner Cache-Control/Vary on post-auth partner errors via the projection context marker, while auth-failed 401s keep public Vary.
- `phase4-coordinator/internal/stats/handlers.go:397-401` reads `stats_rewards_populated`; no request-path query against `provider_rewards_ledger` was found.
- `phase4-coordinator/internal/stats/store/leaderboard.go:56-68` reads `stats_leaderboard_*` plus `provider_visibility`; it does not branch off `provider_visibility_audit` or ad-hoc OLTP sums.
- `phase4-coordinator/internal/stats/handlers.go:495-499` and `handlers.go:541-567` keep `partial_history_since` config-driven and limited to `backfill_mode = partial` on 30d/all windows.
- `phase4-coordinator/internal/stats/middleware.go:50-70` and `middleware.go:85-124` preserve redaction-before-recover with a defensive recover-time Authorization strip.
- `phase4-coordinator/cmd/coordinator/main.go:493-505` mounts `/v1/stats/` through `statsstore.New(statsPools.Reader)` in the existing coordinator binary, preserving the `stats_reader` request-path role boundary.

## Round-(M-1) Closure Checks
- r3 CRITICAL 1 (auth dispatcher applied to `/overview` and `/health`): closed. Evidence: `mux.go:90-132` runs auth-failure + `dispatchAuth` only for `endpoint == "leaderboard"`; `mux.go:133-145` synthesizes a public auth result for `/overview` and `/health`, so irrelevant Authorization no longer changes their status, CORS projection, or partner-key rate tier.
- r3 HIGH 1 (preflight checked only static config, not active `partner_keys.allowed_origins`): closed. Evidence: `cors.go:51-96` calls `isOriginOnGlobalAllowlistUnion`, and `store/store.go:57-89` selects `allowed_origins` from non-revoked `partner_keys` rows.
- r3 MEDIUM 1 (IDNA import outside prompt allowlist): still open; re-raised as MEDIUM 1. Evidence: `origin.go:7` and the required `go list` validation still include `golang.org/x/net/idna`; `.golangci.yml:42-57` documents a local approval but does not change the operator-paste allowlist for this audit.

## Final Verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 10 INFO
