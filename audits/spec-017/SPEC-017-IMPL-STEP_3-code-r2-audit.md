# SPEC-017 IMPL Step 3 — Code Audit Round 2

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `66c63381a87356d3dd76cfbd5ef16856d1498c11` (`impl(017): Step 3 — round-1 audit fixes (3C + 6H + 3M across ARCH/CODE/SECURITY)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r1-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: FAIL — the main §5.1/§5.2/§5.3 DTOs are much closer to lock, but empty leaderboard snapshots emit year-0001 timestamps and `partial_history_since` ignores `backfill_mode`.
B. Header correctness: FAIL — success-path headers and 304 stripping are mostly correct, but non-304 error responses still use `Cache-Control: no-store` / missing endpoint `Vary`, and ETags are not snapshot-stable for overview.
C. Authn flow + crypto: PASS — keyed requests use `sha256([]byte(token))`, lookup before Origin branching, RFC 6454 normalization, and no in-process `==` / `bytes.Equal` secret comparison was found.
D. Rate-limit buckets: FAIL — endpoint dimensions are present and absent Authorization skips auth-failure, but valid partner stale `/overview` responses leak into the auth-failure bucket before refund.
E. Error envelope: PASS — only the six §5.9 codes are present, envelope shape is `{error:{code,message,retry_after_seconds}}`, and 304 is empty.
F. Store correctness: PASS — request-path store is SELECT-only via `stats_reader`, uses `stats_rewards_populated`, avoids forbidden OLTP tables, and LEFT JOINs `provider_visibility`.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS allowlist is explicit, JSON/error writers suppress HEAD bodies, and 405 sets `Allow: GET, HEAD, OPTIONS`.
H. Tests: FAIL — many Step 3-owned ACs and required adversarial assertions remain untested.

## Findings
### CRITICAL
None.

### HIGH
1. `phase4-coordinator/internal/stats/envelope.go:47`
   - Evidence: `writeError` unconditionally sets `Cache-Control: no-store` at lines 48-50 and has no endpoint/projection `Vary` argument. Callers such as invalid leaderboard query errors (`handlers.go:325`), auth 401 (`mux.go:121-123`), 405 (`mux.go:87-89`), rate-limit 429 (`mux.go:177-180`), and stale 503 (`mux.go:136-138`) therefore do not carry the locked four-row Cache-Control/Vary shape.
   - Why: The Step 3 audit target makes wrong `Cache-Control` / `Vary` on any response shape HIGH. §5.9 exempts only 304 from normal bodies; it does not replace the endpoint header table with `no-store` for errors.
   - Fix: Make the error writer receive the endpoint/projection header policy and emit the same Cache-Control/Vary row as the corresponding endpoint response, while preserving `Retry-After`, `Allow`, and `X-Stats-Generated-At`.

2. `phase4-coordinator/internal/stats/mux.go:100`
   - Evidence: Authorization-present requests reserve the auth-failure bucket at lines 100-105 before auth dispatch. A valid partner request then reaches the `/overview` freshness pre-check at lines 131-138, which can return a stale 503 before the success branch refunds the auth-failure reservation at lines 153-156.
   - Why: The auth-failure tier is scoped to Authorization-present requests that produce 401. Valid partner requests that produce stale 503 are currently counted against the auth-failure bucket, so after enough stale valid-key requests the handler can return `429 rate_limited` before auth instead of the required `503 stats_stale`.
   - Fix: Refund the auth-failure reservation immediately after auth success, before any freshness/error pre-check, or defer/centralize refund so every non-401 outcome releases the auth-failure slot.

3. `phase4-coordinator/internal/stats/handlers.go:361`
   - Evidence: `snapshotTime` is only populated from `rows[0].GeneratedAt` when the leaderboard query returns at least one row. If the leaderboard table is empty, `leaderboardStaleFor503` returns `false` for zero time at lines 493-496, and the response serializes `generated_at` and `stale_after` from the zero timestamp at lines 470-472.
   - Why: An empty leaderboard can be a valid page, but `generated_at` still has to identify the rollup snapshot used for the body. Returning `0001-01-01T00:00:00Z` with a derived year-0001 `stale_after` is wrong-on-the-wire and also disables §5.8 stale enforcement for empty windows.
   - Fix: Read the requested window snapshot timestamp independently of returned rows, for example from the relevant `stats_components_health` row or a dedicated snapshot marker, and return 503 when no usable snapshot timestamp exists.

4. `phase4-coordinator/internal/stats/handlers.go:189`
   - Evidence: Overview timeseries alignment is based on request time (`now.Truncate(time.Minute)`) at lines 189-192 and 209-212, while `writeJSON` marshals and hashes the body on every request at lines 659-667. The same `stats_overview_current.generated_at` snapshot can therefore produce different point timestamps and ETags across request-minute boundaries.
   - Why: The locked header contract requires `ETag: W/"<sha256-of-body>"` computed once per snapshot and reused until `generated_at` advances. This implementation can recompute a different body/ETag without a snapshot advance.
   - Fix: Anchor the 30-point grid to the snapshot/rollup bucket boundary rather than request time, and cache or deterministically derive the body/ETag from snapshot data only.

5. `phase4-coordinator/internal/stats/handlers.go:527`
   - Evidence: `Handler` stores `BackfillMode` at lines 18-23, and `cmd/coordinator/main.go` passes `cfg.Stats.Rollup.BackfillMode` plus `PartialHistorySince` at lines 493-502. But `shouldExposePartialHistorySince` checks only non-empty `PartialSince` plus `window in {30d, all}` at lines 527-546; it never verifies `BackfillMode == "partial"`.
   - Why: §9.7 Path B (`backfill_mode = "full"`) must omit `partial_history_since` from day 1. With a stale non-empty `partial_history_since` config left behind, full mode will still emit the field on 30d/all responses.
   - Fix: Gate emission on `BackfillMode == "partial"` and add the required Path A/Path B handler test.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:125`
   - Evidence: The Step 3 handler integration file currently covers AC-1, AC-2, AC-3, AC-7 down-only, AC-12, AC-13, AC-14, AC-21, public earnings-total absence, and public HEAD. It does not implement the required handler tests for AC-4, AC-5, AC-6, AC-11, AC-15, AC-18, AC-22, partner HEAD, stale-503-not-debited, full/partial `partial_history_since`, CORS 7-row coverage, RFC 6454 row coverage, or partner projection headers.
   - Why: Missing tests are MEDIUM under the severity model, and these gaps leave the HIGH findings above unpinned.
   - Fix: Add one clear pass/fail assertion per Step 3-owned AC and each extra Step 3-specific assertion listed in the build prompt.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; prior CODE round `specs/SPEC-017-IMPL-STEP_3-code-r1-audit.md`.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS.
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2/Step 3 audit markdown files in the diff range; no Step 3 Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go` plus comments/tests that assert the lint rule; normal lint passes.
- Store wiring evidence: `cmd/coordinator/main.go:493-505` mounts the stats mux with `statsstore.New(statsPools.Reader)`.
- Store query evidence: `internal/stats/store` uses SELECT-only methods against `stats_overview_current`, `stats_timeseries_*`, `stats_leaderboard_*`, `stats_components_health`, `stats_rewards_populated`, `partner_keys`, and `provider_visibility`; no handler-side `UPDATE/INSERT/DELETE` or request-path SELECT against `provider_rewards_ledger`, `provider_tokens`, `provider_visibility_audit`, or `ledger_*` was found.
- Auth evidence: `phase4-coordinator/internal/stats/auth.go:149-150` computes `sha256.Sum256([]byte(bearer))` and selects by `token_hash`, matching the production `sha256(token_utf8_bytes)` discipline in `internal/auth/tokens.go`.

## Final Verdict
Counts: 0 CRITICAL / 5 HIGH / 1 MEDIUM / 0 LOW / 10 INFO
Verdict: NOT READY TO LOCK
