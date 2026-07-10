# SPEC-017 IMPL Step 3 - Architecture Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `66c63381a87356d3dd76cfbd5ef16856d1498c11` (`impl(017): Step 3 - round-1 audit fixes (3C + 6H + 3M across ARCH/CODE/SECURITY)`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md`

Verdict: NOT READY TO LOCK -
1 CRITICAL + 1 HIGH + 1 MEDIUM + 0 LOW + 8 INFO

## Validation evidence
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/` - scoped Step 3 delta to `cmd/coordinator/main.go`, `go.mod`, and `internal/stats/{auth,cors,envelope,etag,handlers,health_status,middleware,mux,origin,ratelimit}.go` plus `internal/stats/store/*` and Step 3 tests.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/...` - PASS: stats, migrations, rollup; store has no tests.
- `go test -tags=integration -c ./internal/stats` - PASS compile smoke.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` - FAIL against the prompt allowlist because the handler package still imports `golang.org/x/net/idna`; no forbidden internal imports (`internal/ws`, `internal/explorer`, `internal/billing`, `internal/buyer`, `internal/session`) were present.
- `gofmt -l ./internal/stats` - PASS, no output.
- `git diff --check origin/main...HEAD` - FAIL on pre-existing audit markdown trailing whitespace under `specs/SPEC-017-IMPL-STEP_2-*` and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no inspected phase4 Step 3 code whitespace errors were reported.
- `git diff --check bd68a0a..HEAD -- phase4-coordinator/` - PASS, no output.

## Category Verdicts
A. Endpoint + projection scope vs Step 4 boundary: PASS - Step 3 stays in handler/middleware/store scope and does not implement the partner-key CLI, nginx, or observability surfaces.
B. Middleware stack ordering: PASS - redaction, recover, auth-failure reservation, auth dispatch, success bucket, and handlers are sequenced correctly; stale paths are no longer permanently debited.
C. §5.4.3 partner-key authn flow: PASS - present malformed Authorization now returns 401, keyed requests hash+SELECT before origin branching, and no `last_used_at` write is present.
D. CORS per §5.7: PASS - preflight is key-agnostic with 204 / max-age 60; partner success responses echo Origin or omit ACAO rather than emitting `*`.
E. Header surface: FAIL - overview response bodies, and therefore ETags, are request-time aligned instead of snapshot-aligned.
F. Endpoint contract: FAIL - empty leaderboard pages can return a successful year-1 `generated_at`/`stale_after` instead of the Step 2 window snapshot time.
G. 503 + rate-limit semantics: PASS with caveat - stale 503s are refunded/skipped for normal non-empty snapshots; empty leaderboard freshness is raised under the endpoint contract finding.
H. Failure modes + main.go integration: FAIL - main uses the `stats_reader` store and same binary mount, but the handler package import graph still exceeds the prompt allowlist.

## Findings
### CRITICAL
1. `phase4-coordinator/internal/stats/handlers.go:170`
   - Evidence: overview JSON aligns `rpm_30m` / `tpm_30m` points with request-time `now` (`handlers.go:123`, `handlers.go:170`, `handlers.go:174`) while the response declares `generated_at` and `X-Stats-Generated-At` from `stats_overview_current.generated_at` (`handlers.go:149`, `handlers.go:179`). `writeJSON` then hashes that request-time body into the ETag (`handlers.go:660-667`).
   - Why: SPEC §5.1 locks `ETag: W/"<sha256-of-body>"` as computed once per rollup snapshot and reused until `generated_at` advances. BUILD Step 3 likewise says the weak ETag is snapshot-derived. With an unchanged DB snapshot, two requests in different minutes can shift the 30-point timestamp window, producing a different body and ETag while `generated_at` is unchanged. That is the audit prompt's CRITICAL "ETag computed off-snapshot" class.
   - Fix: derive the 30-point alignment anchor from the snapshot, not request time: use `ov.GeneratedAt.Truncate(time.Minute)` or a single rollup-snapshot anchor shared by overview/timeseries. Add a regression that freezes the store rows, advances handler `Now`, and asserts body/ETag remain stable until `stats_overview_current.generated_at` changes.

### HIGH
1. `phase4-coordinator/internal/stats/handlers.go:361`
   - Evidence: leaderboard snapshot time is taken only from `rows[0].GeneratedAt` (`handlers.go:361-364`). If the requested leaderboard table has zero rows, `snapshotTime` stays zero; the empty branch calls `leaderboardStaleFor503`, but that helper returns `false` for zero time (`handlers.go:365-380`, `handlers.go:493-496`). The handler then emits `generated_at` and `stale_after` from the zero time (`handlers.go:470-472`). Step 2 does maintain a valid per-window tick timestamp in `stats_components_health` even when no rows are inserted (`rollup/leaderboard.go:73-83`, `rollup/health.go:31-38`).
   - Why: SPEC §5.2 requires `generated_at` to be the requested window's rollup snapshot timestamp, and §5.8 requires staleness to be evaluated against that window's snapshot. An empty leaderboard is a valid page, but it still needs the window's successful rollup time; returning `0001-01-01T00:00:00Z` as a 200 response is neither a Step 2 snapshot nor a conforming stale decision.
   - Fix: add a store method that reads `stats_components_health.generated_at` for `leaderboard_<window>` and use it as the snapshot timestamp when the page has zero rows. Treat missing/epoch/stale component timestamps as `503 stats_stale`; use the same timestamp for `generated_at`, `stale_after`, `X-Stats-Generated-At`, and ETag tests.

### MEDIUM
1. `phase4-coordinator/internal/stats/origin.go:7`
   - Evidence: `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` reports `golang.org/x/net/idna`. The audit prompt's handler-package allowlist is standard library, `internal/auth` for shared hash helpers only, `internal/config`, `internal/stats/store`, optional `internal/pool`, and `github.com/rs/zerolog`.
   - Why: this is the same round-1 ARCH MEDIUM import-boundary finding. The IDNA dependency is understandable for RFC 6454 normalization, but it remains outside the explicit Step 3 request-path import boundary; two conforming Step 3 sessions could still disagree between keeping the dependency and moving/approving the helper.
   - Fix: either amend the controlling Step 3 dependency boundary to explicitly allow `golang.org/x/net/idna`, or move the IDNA normalization behind an approved local helper/package and update the allowlist/tests accordingly.

### LOW
- None.

### INFO
- `phase4-coordinator/internal/stats/mux.go:126-139` performs the overview stale pre-check before the success bucket, closing the round-1 stale-503 debit issue for overview.
- `phase4-coordinator/internal/stats/mux.go:150-175` records handler status and refunds public/partner success buckets on non-2xx/503-like responses, closing the round-1 leaderboard stale-debit class for normal stale responses.
- `phase4-coordinator/internal/stats/middleware.go:52-60` and `auth.go:120-135` distinguish present malformed Authorization from absent Authorization and return 401 instead of public projection.
- `phase4-coordinator/internal/stats/envelope.go:30-69` now emits the §5.9 `message` / optional `retry_after_seconds` shape and sets `Retry-After` plus `X-Stats-Generated-At` on non-304 errors.
- `phase4-coordinator/internal/stats/etag.go:20-22` now emits the full 64-hex SHA-256 digest.
- `phase4-coordinator/internal/stats/store/leaderboard.go:143-158` now reads `stats_rewards_populated.rewards_populated` by `window_label` rather than synchronously querying the rewards ledger.
- `phase4-coordinator/internal/stats/health_status.go:27-57` uses the §9.5 per-window health thresholds, and `handlers.go:573-581` emits the locked 7-component health map.
- `phase4-coordinator/cmd/coordinator/main.go:493-505` mounts the same stats handler subtree through the coordinator binary with `statsstore.New(statsPools.Reader)`, preserving the `stats_reader` request-path isolation.

## Round-(M-1) Closure Checks
- r1 CRITICAL 1 (stale 503 debits success bucket): closed for overview and non-empty leaderboard stale paths. Evidence: `mux.go:126-139` pre-checks overview before success debit; `mux.go:150-175` refunds non-2xx/503-like handler responses.
- r1 CRITICAL 2 (leaderboard stale 503 absent): closed for non-empty leaderboard snapshots. Evidence: `handlers.go:356-380` applies the §9.5 per-window budgets. New HIGH 1 covers the separate empty-table snapshot case.
- r1 CRITICAL 3 (malformed Authorization becomes public projection): closed. Evidence: `middleware.go:52-60` records Authorization presence regardless of parse success; `auth.go:120-135` maps parse failure with a present header to 401.
- r1 HIGH 1 (overview JSON shape): closed structurally. Evidence: `handlers.go:60-114` defines the §5.1 overview DTO and nullable timeseries point shapes. New CRITICAL 1 covers snapshot-time alignment, not field presence.
- r1 HIGH 2 (leaderboard JSON shape/page totals): closed for non-empty pages. Evidence: `handlers.go:236-285` defines `limit`, single `rank`, single `earnings_bucket`, single `exact_earnings`, and partner-only totals; `handlers.go:391-460` computes page totals over returned rows. New HIGH 1 covers empty-page snapshot metadata.
- r1 HIGH 3 (`RewardsPopulated` reads wrong column): closed. Evidence: `store/leaderboard.go:143-158`.
- r1 HIGH 4 (error envelope schema/retry field): closed. Evidence: `envelope.go:30-69`.
- r1 HIGH 5 (health shape/thresholds): closed. Evidence: `handlers.go:553-647` and `health_status.go:27-76`.
- r1 HIGH 6 (401 rejected-origin CORS emitted public `*`): closed. Evidence: unauthorized path at `mux.go:115-123` sets public Vary and writes the error without calling `writeCORSHeaders`, so no `Access-Control-Allow-Origin: *` is emitted on keyed 401s.
- r1 MEDIUM 1 (IDNA import outside allowlist): still open; re-raised as MEDIUM 1.
- r1 MEDIUM 2 (ETag truncated): closed. Evidence: `etag.go:20-22`.
- r1 MEDIUM 3 (`X-Stats-Generated-At` missing on errors): closed. Evidence: `envelope.go:47-56`.

## Final Verdict
READY TO LOCK: NO
Blocking count: 1 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW / 8 INFO
