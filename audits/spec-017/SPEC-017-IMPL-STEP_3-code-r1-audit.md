# SPEC-017 IMPL Step 3 — Code Audit Round 1

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `9c2976571c3d76a6849f5f965b5320d5b3eb9e27` (`impl(017): Step 3 — handlers + middleware + store (initial drop for audit loop)`)
Prior round: none
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: FAIL — overview, leaderboard, health, and error envelopes do not match locked §5.1/§5.2/§5.3/§5.9.
B. Header correctness: FAIL — `X-Stats-Generated-At` is absent on non-304 error responses; HEAD stale/error paths write body bytes.
C. Authn flow + crypto: PASS with caveat — keyed requests use `sha256([]byte(token))` and no Origin/prefix early return; `subtle.ConstantTimeCompare` is present, but only as a no-op self-compare after a DB lookup.
D. Rate-limit buckets: FAIL — success buckets are debited before stale handling, so stale 503s consume quota.
E. Error envelope: FAIL — code vocabulary is closed, but the envelope shape uses `detail` and omits required `message` / `retry_after_seconds`.
F. Store correctness: FAIL — handler store is read-only and avoids forbidden OLTP tables, but `RewardsPopulated` selects a non-existent column.
G. HEAD + 405: FAIL — 405 path sets `Allow`, but HEAD stale/error responses write body bytes.
H. Tests: FAIL — many Step 3-owned ACs are not implemented; the integration tick helper is a no-op and AC-1 assertions encode the wrong spec shape.

## Findings
### CRITICAL
1. `phase4-coordinator/internal/stats/envelope.go:36`
   - Evidence: `writeError` always encodes a JSON body and has no `HEAD` guard. `handleOverview` calls `writeError` for stale snapshots at `phase4-coordinator/internal/stats/handlers.go:83`, so `HEAD /v1/stats/overview` on the stale path writes body bytes.
   - Why: The prompt severity model marks `HEAD returns body bytes` as CRITICAL. Locked §4.3 requires HEAD on every GET to return identical headers with an empty body.
   - Fix: Pass the request method into the error writer, or add a HEAD-aware wrapper, and suppress all body writes for HEAD across 400/401/405/429/500/503 paths while preserving headers.

### HIGH
1. `phase4-coordinator/internal/stats/handlers.go:39`
   - Evidence: The overview response omits `stale_after`, `network.tokens_served_total`, and `network.avg_tokens_per_request`; it emits `timeseries.rpm_requests`, `tpm_input_tokens`, and `tpm_output_tokens` arrays plus `meta.window_seconds` instead of the locked `timeseries.rpm_30m.points[]` and `timeseries.tpm_30m.points[]` objects with timestamps.
   - Why: Locked §5.1/§5.1.1 require the exact overview JSON shape and 14 `network.*` fields. This is wrong-on-the-wire for `GET /v1/stats/overview`.
   - Fix: Rebuild the overview DTO to match §5.1 exactly: add `stale_after`, all 14 network fields, and timestamped `rpm_30m` / `tpm_30m` point arrays with null values for missing minutes.

2. `phase4-coordinator/internal/stats/handlers.go:178`
   - Evidence: The leaderboard response omits `stale_after` and `limit`, emits `rank_earnings` / `rank_tokens` / `rank_jobs` instead of a single `rank`, and declares USD fields as `string`, which marshals as JSON strings rather than numeric USD values.
   - Why: Locked §5.2 pins the leaderboard wire shape. Wrong JSON shape on any endpoint is HIGH by the prompt severity model.
   - Fix: Add `stale_after` and `limit`, emit a single rank for the selected sort axis, and marshal USD values as JSON numbers with two-decimal precision rather than strings.

3. `phase4-coordinator/internal/stats/store/leaderboard.go:139`
   - Evidence: `RewardsPopulated` runs `SELECT populated FROM stats_rewards_populated`, but the migration creates `rewards_populated` at `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:191`.
   - Why: Every leaderboard request reaches this query before writing JSON, so production will return `500 internal` instead of any §5.2 leaderboard body.
   - Fix: Select `rewards_populated` and add a handler/store test against the actual migrated schema.

4. `phase4-coordinator/internal/stats/handlers.go:374`
   - Evidence: The health response omits required `rollup_lag_seconds`; it only emits whatever rows exist in `stats_components_health` and does not enforce exactly seven component keys. `thresholdsForComponent` also uses wrong budgets for `leaderboard_7d`, `leaderboard_30d`, and `leaderboard_all` at `phase4-coordinator/internal/stats/health_status.go:40`.
   - Why: Locked §5.3 requires `rollup_lag_seconds`, exactly seven component keys, and §9.5 thresholds. This can report the wrong health status on the wire.
   - Fix: Compute `rollup_lag_seconds`, materialize the exact seven-key component map, and align budgets to §9.5: 7d `1800s`, 30d `14400s`, all `86400s`.

5. `phase4-coordinator/internal/stats/envelope.go:24`
   - Evidence: The error body is `{code, detail}`. Locked §5.9 requires `{code, message, retry_after_seconds}` with `retry_after_seconds` on `rate_limited` and `stats_stale`.
   - Why: This is a wrong JSON shape for every non-2xx error response except 304.
   - Fix: Replace `detail` with `message`; add optional `retry_after_seconds`, and populate it for 429 and 503.

6. `phase4-coordinator/internal/stats/mux.go:142`
   - Evidence: The post-auth success limiter calls `allow` before dispatching to the handler. `handleOverview` emits stale 503 inside the handler, so stale requests have already consumed the public or partner success bucket.
   - Why: Locked §5.8 / Step 3 middleware rules require stale 503 responses to occur before success-bucket debit; otherwise an outage can exhaust quotas and later fresh requests return 429.
   - Fix: Check staleness before success-bucket debit, or make the limiter reserve/refund based on the final status code for non-2xx responses.

7. `phase4-coordinator/internal/stats/handlers.go:220`
   - Evidence: `/v1/stats/leaderboard` never checks the requested window's `generated_at` against §9.5 503 budgets; it always writes 200 after store reads.
   - Why: Locked §5.8 requires 503 when a leaderboard window is older than its budget. This is wrong-on-the-wire for stale 24h/7d/30d/all snapshots.
   - Fix: Apply per-window stale checks before writing the leaderboard response.

8. `phase4-coordinator/internal/stats/envelope.go:36`
   - Evidence: `writeError` sets `Cache-Control: no-store` and does not set `X-Stats-Generated-At`. The Step 3 prompt requires `X-Stats-Generated-At` on every non-304 `/v1/stats/*` response, and only exempts 304.
   - Why: Wrong header shape on any response is HIGH under the prompt severity model.
   - Fix: Centralize stats response headers for non-304 errors, including `X-Stats-Generated-At` where a snapshot timestamp is available and the correct endpoint/projection cache and vary headers where specified.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:97`
   - Evidence: AC-1 test comments say the spec has 12 network fields and asserts the implementation's flattened `timeseries.rpm_requests` shape. Locked §5.1.1 requires 14 network fields and §5.1 requires `rpm_30m.points` / `tpm_30m.points`.
   - Why: The test suite locks in the wrong contract and would not catch HIGH finding 1.
   - Fix: Rewrite AC-1 assertions directly from locked §5.1/§5.1.1.

2. `phase4-coordinator/internal/stats/handlers_integration_test.go:374`
   - Evidence: `driveRollupTick` is a no-op placeholder, and the file does not implement AC-4, AC-5, AC-6 partner projection, AC-7 health fixtures, AC-11, AC-14, AC-15, AC-18, AC-19, AC-22, CORS row coverage, partial-history coverage, or 503-not-debited coverage.
   - Why: Missing tests are MEDIUM per the prompt severity model, and the absent coverage allowed multiple wrong-on-the-wire bugs.
   - Fix: Replace placeholders with real fixtures and add one explicit assertion per Step 3-owned AC.

3. `phase4-coordinator/internal/stats/auth.go:141`
   - Evidence: The only `subtle.ConstantTimeCompare` call compares `hash[:]` to itself after the SQL lookup on revoked keys. There is no meaningful in-process secret comparison to make constant-time.
   - Why: This is not currently a wire bug because lookup is DB equality on `token_hash`, but the code comment can mislead future maintainers into believing revoked/no-row timing is hardened by that call.
   - Fix: Remove the no-op comparison or replace it with a meaningful constant-time comparison only if an in-process secret comparison is introduced.

### LOW
1. `phase4-coordinator/internal/stats/forbidigo_fixture.go:9`
   - Evidence: The required grep command matches the deliberate `linttest_fixture` `os.Exit(1)` at line 16.
   - Why: The fixture is useful for lint verification, but it makes the literal banned-call grep fail unless auditors know to exclude build-tagged fixtures.
   - Fix: Move the fixture outside `internal/stats/` or update the audit grep to exclude `//go:build linttest_fixture` files.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; no prior Step 3 CODE audit files exist for round 1.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS.
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL, but failures are pre-existing trailing whitespace in Step 2 audit markdown files included by the diff range, not Step 3 handler code.
- Required banned-call grep: FAIL by literal output because it matches the intentional `linttest_fixture` file `phase4-coordinator/internal/stats/forbidigo_fixture.go`; normal lint still passes.
- Store request path uses `stats_reader` via `statsstore.New(statsPools.Reader)` in `cmd/coordinator/main.go:493` and the handler store issues SELECT-only queries against `stats_*`, `partner_keys`, and `provider_visibility`; no handler-side `UPDATE/INSERT/DELETE` or forbidden OLTP table SELECT was found.
- Auth hashing uses `sha256.Sum256([]byte(bearer))` in `phase4-coordinator/internal/stats/auth.go:121`, matching the production `sha256(token_utf8_bytes)` discipline in `internal/auth/tokens.go:128`.

## Final Verdict
Counts: 1 CRITICAL / 8 HIGH / 3 MEDIUM / 1 LOW / 10 INFO
Verdict: NOT READY TO LOCK
