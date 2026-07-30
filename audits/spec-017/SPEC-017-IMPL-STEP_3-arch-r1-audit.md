# SPEC-017 IMPL Step 3 - Architecture Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `9c29765` (`impl(017): Step 3 - handlers + middleware + store (initial drop for audit loop)`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- None. This is round 1.

Verdict: NOT READY TO LOCK -
3 CRITICAL + 6 HIGH + 3 MEDIUM + 0 LOW + 6 INFO

## Validation evidence
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/` - scoped Step 3 delta to `cmd/coordinator/main.go`, `go.mod`, and new `internal/stats/{auth,cors,envelope,etag,handlers,health_status,middleware,mux,origin,ratelimit}.go` plus `internal/stats/store/*`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/...` - PASS: stats, migrations, rollup; store has no tests.
- `go test -tags=integration -c ./internal/stats` - PASS compile smoke.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` - FAIL against the prompt allowlist because the handler package imports `golang.org/x/net/idna`; no forbidden internal imports (`internal/ws`, `internal/explorer`, `internal/billing`, `internal/buyer`, `internal/session`) were present.
- `gofmt -l ./internal/stats` - PASS, no output.
- `git diff --check origin/main...HEAD` - FAIL on pre-existing Step 2 audit markdown trailing whitespace under `specs/SPEC-017-IMPL-STEP_2-*`; no phase4 Step 3 code whitespace errors were reported.
- `git diff --check bd68a0a..HEAD -- phase4-coordinator/ specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md` - PASS, no output.

## Category Verdicts
A. Endpoint + projection scope vs Step 4 boundary: FAIL - Step 3 stays mostly in scope, but the endpoint wire contracts are not the locked Step 3 contracts.
B. Middleware stack ordering: FAIL - the stack is ordered, but success-bucket accounting runs before stale/error status is known.
C. §5.4.3 partner-key authn flow: FAIL - malformed/present Authorization can fall through to anonymous public projection instead of 401.
D. CORS per §5.7: FAIL - auth-failed partner-origin rejections emit public `ACAO: *` instead of omitting CORS allow headers.
E. Header surface: FAIL - error envelopes lack required retry fields, non-304 errors lack `X-Stats-Generated-At`, and ETag truncates the SHA-256.
F. Endpoint contract: FAIL - overview, leaderboard, and health JSON shapes diverge from §5.1-§5.3.
G. 503 + rate-limit semantics: FAIL - stale leaderboard 503 is absent, and stale/error paths debit success buckets.
H. Failure modes + main.go integration: PASS with caveat - main wires the same binary and `stats_reader` store, but request-path package import allowlist fails on `golang.org/x/net/idna`.

## Findings
### CRITICAL
1. `phase4-coordinator/internal/stats/mux.go:142`
   - Evidence: the post-auth success limiter increments at `mux.go:145-168` before dispatching to `handleOverview` / `handleLeaderboard` / `handleHealth` at `mux.go:170-178`; the overview stale branch returns 503 later at `handlers.go:83-91`.
   - Why: BUILD Step 3 lines 398 and 440 require stale 503 responses to be emitted before the success-bucket debit, and the success bucket tracks successful 2xx accounting only. As written, repeated stale 503s can exhaust the public or partner success quota.
   - Fix: move success-bucket accounting behind a response-status capture, or perform all cheap freshness checks before debiting; refund or skip accounting for every non-2xx/304 path.

2. `phase4-coordinator/internal/stats/handlers.go:256`
   - Evidence: `handleLeaderboard` reads rows/totals/rewards and writes 200 at `handlers.go:256-341`; there is no comparison of `totals.GeneratedAt` or row snapshot time against the §9.5 per-window 503 budgets.
   - Why: SPEC §5.8 requires `/v1/stats/leaderboard` to return 503 when the requested `stats_leaderboard_<window>.generated_at` exceeds the §9.5 budget: 300s, 30m, 4h, or 24h by window.
   - Fix: after loading the requested window snapshot and before success-bucket debit, apply the locked per-window stale budget and return `503 stats_stale` with `Retry-After: 30`.

3. `phase4-coordinator/internal/stats/middleware.go:41`
   - Evidence: redaction only stores a bearer token when `parseBearer` succeeds (`middleware.go:41-45`); `dispatchAuth` treats missing context as row 1 anonymous public projection (`auth.go:104-117`). A present but malformed/non-Bearer Authorization header therefore bypasses 401.
   - Why: SPEC §5.2 says an invalid `Authorization` header returns 401, and §5.6 scopes the auth-failure tier to Authorization-present requests before auth dispatch. Treating malformed Authorization as absent changes the §5.4.3 auth boundary.
   - Fix: store both raw Authorization presence and parse result in context; reserve the auth-failure bucket on header presence; return `401 unauthorized` for malformed/empty/non-Bearer Authorization rather than public projection.

### HIGH
1. `phase4-coordinator/internal/stats/handlers.go:39`
   - Evidence: `overviewResponse` lacks top-level `stale_after`, lacks `network.tokens_served_total` and `network.avg_tokens_per_request`, adds non-spec `meta.window_seconds`, and emits flat arrays `rpm_requests`, `tpm_input_tokens`, `tpm_output_tokens` (`handlers.go:39-72`, `105-127`) instead of `timeseries.rpm_30m.points[]` / `tpm_30m.points[]`.
   - Why: SPEC §5.1 and BUILD Step 3 AC-1 lock the overview JSON shape: 14 network fields plus two 30-point timeseries objects with timestamped points and nulls for missing minutes.
   - Fix: replace the overview DTO with the §5.1 wire DTO, derive `tokens_served_total` and `avg_tokens_per_request`, add `stale_after`, and encode timestamped 30-point `rpm_30m` / `tpm_30m` objects.

2. `phase4-coordinator/internal/stats/handlers.go:178`
   - Evidence: `leaderboardResponse` lacks `stale_after` and `limit`; rows emit `rank_earnings`, `rank_tokens`, and `rank_jobs` instead of one selected `rank`; exact dollar values are string fields (`handlers.go:178-214`, `319-341`). `LeaderboardTotals` aggregates the whole table, not the returned `(window, sort, limit)` page (`store/leaderboard.go:109-123`).
   - Why: SPEC §5.2 locks a page-shaped leaderboard: top-level `limit` / `stale_after`, one `rank` per row, numeric exact-dollar fields, and totals over the same requested page.
   - Fix: build the page once in sort order, compute page totals from that page, emit one `rank`, add `limit` and `stale_after`, and marshal exact dollars as JSON numbers with two-decimal precision.

3. `phase4-coordinator/internal/stats/store/leaderboard.go:139`
   - Evidence: `RewardsPopulated` queries `SELECT populated FROM stats_rewards_populated` (`store/leaderboard.go:139-148`), but the locked Step 2 table column is `rewards_populated` (`migrations/001_stats_tables.up.sql:191-195`).
   - Why: Step 3 inherits Step 2 storage. This DAO will fail every leaderboard request at runtime with an undefined-column SQL error instead of returning required `meta.rewards_populated`.
   - Fix: query `rewards_populated` by `window_label`; add an integration test seeded from the Step 2 migration.

4. `phase4-coordinator/internal/stats/envelope.go:24`
   - Evidence: the envelope serializes `{"error":{"code":...,"detail":...}}` (`envelope.go:24-43`), while 429/503 callers only set the HTTP `Retry-After` header (`mux.go:121-122`, `165-166`, `handlers.go:89-90`) and never emit `retry_after_seconds`.
   - Why: SPEC §5.9 locks `message` and `retry_after_seconds` for `rate_limited` and `stats_stale`; introducing `detail` instead is a wire-schema drift.
   - Fix: change the envelope to `code`, `message`, and optional `retry_after_seconds`; thread retry seconds through 429 and 503 writers.

5. `phase4-coordinator/internal/stats/handlers.go:374`
   - Evidence: `healthResponse` omits `rollup_lag_seconds` (`handlers.go:374-417`). `thresholdsForComponent` uses non-spec 503 budgets for `leaderboard_7d`, `leaderboard_30d`, and `leaderboard_all` (`health_status.go:27-46`), and treats any component past its budget as `down`.
   - Why: SPEC §5.3 requires `rollup_lag_seconds`; §9.5 sets 7d/30d/all budgets to 30m/4h/24h; §5.3 says top-level `down` is driven by overview or leaderboard_24h beyond budget.
   - Fix: compute lag from the oldest component, use the exact §9.5 budget table, and align top-level status derivation with §5.3.

6. `phase4-coordinator/internal/stats/mux.go:133`
   - Evidence: every 401 path sets public Vary and calls `writeCORSHeaders(..., false, ...)`, which emits `Access-Control-Allow-Origin: *` (`mux.go:133-138`, `cors.go:74-87`).
   - Why: SPEC §5.7 rows 6-7 require rejected partner-key requests with non-empty allowlists to omit CORS allow headers; echoing public `*` on rejected-origin auth failures contradicts the locked table.
   - Fix: carry the auth failure reason/projection context and omit CORS allow headers for partner-key origin rejection and absent-origin rejection; keep public `ACAO: *` only for true no-key public responses.

### MEDIUM
1. `phase4-coordinator/internal/stats/origin.go:7`
   - Evidence: `go list` shows `golang.org/x/net/idna` imported by `internal/stats`, and `go.mod` adds `golang.org/x/net v0.26.0`.
   - Why: the audit prompt's handler-package allowlist permits standard library, `internal/auth`, `internal/config`, `internal/stats/store`, optional `internal/pool`, and `github.com/rs/zerolog`. The IDNA dependency is understandable for RFC 6454 normalization, but it is outside the explicit Step 3 import boundary.
   - Fix: either move/approve the IDNA helper through the controlling spec/build prompt, or implement normalization through an already-allowed local helper so the handler package import graph matches the pinned boundary.

2. `phase4-coordinator/internal/stats/etag.go:16`
   - Evidence: `weakETag` computes SHA-256 but encodes only `sum[:16]` (`etag.go:16-18`) while documenting a 128-bit truncation.
   - Why: SPEC §5.1 and BUILD Step 3 lock `ETag: W/"<sha256-of-body>"`; truncating the digest makes this no longer the SHA-256 of the body.
   - Fix: encode the full `sha256.Sum256` byte slice.

3. `phase4-coordinator/internal/stats/envelope.go:36`
   - Evidence: `writeError` sets `Content-Type` and `Cache-Control` only (`envelope.go:36-43`); 400/401/429/500/503 responses do not get `X-Stats-Generated-At`.
   - Why: BUILD Step 3 line 420 requires `X-Stats-Generated-At` on every non-304 `/v1/stats/*` response. The current helper makes all error paths structurally miss that header.
   - Fix: route stats errors through an error writer that receives the relevant snapshot generated time, or define and consistently apply a SPEC-conforming generated-at source for error paths.

### LOW
- None.

### INFO
- `cmd/coordinator/main.go:493-505` mounts `/v1/stats/` from the same coordinator binary and injects `statsstore.New(statsPools.Reader)`, matching the §7.1 / §7.2.1 role boundary.
- `mux.go:99-107` explicitly allows `GET` and `HEAD`, returns 405 with `Allow: GET, HEAD, OPTIONS` for other methods.
- `middleware.go:64-93` wraps the stats subtree with panic recovery and defensively redacts `Authorization` before logging.
- `auth.go:119-128` performs `sha256 + SELECT` before origin allowlist branching for parsed Bearer tokens, preserving the core row 5/6/7 timing shape.
- `store/leaderboard.go:56-68` reads from `stats_leaderboard_*` and `provider_visibility`, not ad-hoc OLTP sums or `provider_visibility_audit`.
- `handlers.go:328-332` sources `partial_history_since` from injected config, not a hot-path DB read.

## Round-(M-1) Closure Checks
- Not applicable. No prior Step 3 ARCH audit rounds exist.

## Final Verdict
READY TO LOCK: NO
Blocking count: 3 CRITICAL / 6 HIGH / 3 MEDIUM / 0 LOW / 6 INFO
