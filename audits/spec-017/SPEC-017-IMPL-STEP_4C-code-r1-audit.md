# SPEC-017 IMPL Step 4.C - Code Audit Round 1

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `2130a87c0fe34319b9f505eb68890b156ed441fd`
Diff base checked: `HEAD^` (`022cd553fdc1b9ab06f149c7a1add4a4397b793c`)
Auditor lane: CODE

Verdict: NOT READY TO LOCK -
0 CRITICAL + 5 HIGH + 3 MEDIUM + 2 LOW + 8 INFO

## Validation evidence

- Required reading completed: `CLAUDE.md`; `SPEC-017-network-stats-api.md` v0.1.8 sections 6.6.2, 8.5, 9.4, 9.5, 9.6, and AC-1..AC-22; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC matrix; Step 3 convergence; Step 4.B CODE/SECURITY r4 lock audits.
- Step 4.C diff scope: `git diff --name-only HEAD^..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`.
- Event sweep: `rg` found emit sites for `stats_request_served`, `stats_rollup_tick_completed`, `stats_rollup_drift_detected`, `stats_handler_panic`, `stats_partner_key_issued`, and `stats_partner_key_revoked`.
- Metric sweep: `metrics.New` declares the five required metric names with CounterVec/GaugeVec types.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `golangci-lint run ./...` from `phase4-coordinator/` - PASS.
- Literal `gofmt -l ./...` - FAIL because gofmt does not accept package pattern `./...` (`lstat ./...: no such file or directory`). Equivalent file-based command `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l` reported `./internal/buyer/transport_result_test.go` and `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C diff.
- `git diff --check HEAD^..HEAD -- phase4-coordinator/ OPS.md docs/ specs/` - FAIL: `specs/SPEC-017-IMPL-STEP_4B-security-r4-audit.md:169: new blank line at EOF`.

## Findings

### CRITICAL

None.

### HIGH

1. `stats_rate_limit_exceeded_total` records auth-failure limiter 429s as `tier="public"` instead of `tier="auth_failure"`.
   - Evidence: the auth-failure limiter rejects at `phase4-coordinator/internal/stats/mux.go:105-112` with no metric context. The outer access middleware later derives tier only from `partner_key_id` at `phase4-coordinator/internal/stats/middleware.go:190-199`, so an invalid-Bearer flood rejected by the auth-failure bucket lands as `stats_rate_limit_exceeded_total{tier="public",endpoint="leaderboard"}`. The metric package itself documents and tests `auth_failure` as an allowed tier at `phase4-coordinator/internal/stats/metrics/metrics.go:86-91` and `metrics_test.go:51-52`.
   - Why it matters: dashboards/alerts cannot distinguish public quota exhaustion from the SPEC v0.1.8 auth-failure flood path, silently breaking the Step 4.C metric contract.
   - Fix direction: carry the limiter tier through request observability, or increment `RateLimitExceededTotal.WithLabelValues("auth_failure", endpoint)` at the auth-failure reject site while avoiding double-counting in the outer middleware.

2. `stats_rollup_errors_total` does not increment for nightly rebuild SQL errors or panics.
   - Evidence: per-table `runOne` increments `RollupErrorsTotal` on panic/error at `phase4-coordinator/internal/stats/rollup/runner.go:209-224`, but nightly rebuild errors only log at `runner.go:293-295`; the nightly rebuild panic defer at `runner.go:267-274` also logs without touching the metric.
   - Why it matters: SPEC §9.6 says rollup SQL errors increment `stats_rollup_errors_total`; §9.4 nightly rebuild is a rollup path. The most correctness-sensitive rebuild failure path is invisible to the required counter.
   - Fix direction: increment the counter for the affected rebuild components (`leaderboard_30d` / `leaderboard_all`) on nightly rebuild error/panic, or split the rebuild into component-specific observed calls.

3. `stats_rollup_tick_completed` emits an empty `component` for the `rewards_populated` tick.
   - Evidence: `Start` spawns the rewards-populated tick as `name="rewards_populated"` but `c=""` at `phase4-coordinator/internal/stats/rollup/runner.go:115-119`. Successful ticks then log `component` from `string(c)` at `runner.go:233-239`, producing `component=""`.
   - Why it matters: the required event field is present syntactically but semantically missing. Consumers grouping rollup completion by component will get an empty component bucket.
   - Fix direction: either do not emit `stats_rollup_tick_completed` for non-component ticks, or log the job name as the component-equivalent field for this tick with a bounded allowed value.

4. Step 4.C does not land the required end-of-implementation AC sweep/convergence file.
   - Evidence: `find specs -maxdepth 1 -name 'SPEC-017-IMPL-STEP_4C*convergence*' -o -name 'SPEC-017-IMPL-STEP_4C-r*-convergence.md'` returned no files. The Step 4.C diff adds audit locks for Step 4.B but no final file listing all 22 ACs with test paths.
   - Why it matters: BUILD §2.4 makes the 22-AC final sweep a Step 4.C deliverable. Without it, there is no implementation-owned record that AC-1..AC-22 were re-walked at the end of the PR.
   - Fix direction: add `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md` or equivalent after fixes, listing all 22 ACs, owner step, concrete test path/CI job, and latest validation evidence.

5. The new Step 4.C event emitters are not tested through their emit paths.
   - Evidence: `rg -n "stats_handler_panic|stats_request_served|stats_rollup_tick_completed|stats_partner_key_issued|stats_partner_key_revoked" ... -g '*_test.go'` returned no hits. Only the pre-existing drift event has direct tests (`phase4-coordinator/internal/stats/rollup/rebuild_test.go:53` and `:72`).
   - Why it matters: the prompt requires every new emitter to run once and assert the value lands. Missing tests allowed the empty `stats_rollup_tick_completed.component` issue above and leaves partner-key issue/revoke event field sets unpinned.
   - Fix direction: add focused tests for request-served, tick-completed, handler-panic, partner-key-issued, and partner-key-revoked event lines, asserting required fields and forbidden token/hash substrings.

### MEDIUM

1. The metric-label hygiene test does not drive a real request through the Step 3 mux.
   - Evidence: `TestLabelHygiene` instantiates a fresh registry but manually calls `WithLabelValues(...).Inc()` / `.Set()` at `phase4-coordinator/internal/stats/metrics/metrics_test.go:37-53`; it never constructs `stats.NewMuxWithMetrics`, never sends a request, and never exercises the limiter/auth paths.
   - Why it matters: category G requires the hygiene test to drive a real request through the Step 3 mux and scrape the emitted labels. The current test validates hand-written sample labels, not the production label derivation.
   - Fix direction: add an in-process mux test that serves public, partner, and auth-failure/rate-limited requests, gathers the registry, and scans every emitted label value.

2. `stats_rollup_lag_seconds` has no test that runs its production update path.
   - Evidence: the production updater is `observeRollupLag` at `phase4-coordinator/cmd/coordinator/main.go:930-975`; the only test reference to `RollupLagSeconds` is the manual `Set` in `metrics_test.go:48-49`.
   - Why it matters: category I requires every new metric emitter to run once and assert the value lands. The gauge query path can regress independently from metric declaration.
   - Fix direction: extract or test the single-pass lag observation logic against a small SQL fixture, or add a test seam that runs one update and gathers the gauge.

3. OPS.md runbook entries do not consistently include recovery steps for command failure.
   - Evidence: the four entries exist at `OPS.md:623-691` and include invocation commands plus expected effects, but the rotate/revoke/visibility sections do not say what to do if the command exits non-zero or partially succeeds. The prompt requires invocation command, expected outcome, and recovery step if it fails for each entry.
   - Why it matters: this is a deliverable-shape gap rather than a runtime bug, but it blocks the Step 4.C code-lane checklist as written.
   - Fix direction: add a short "If this fails" paragraph under each of the four entries.

### LOW

1. `gofmt` validation is dirty outside the Step 4.C diff.
   - Evidence: file-based gofmt check reported `phase4-coordinator/internal/buyer/transport_result_test.go` and `phase4-coordinator/internal/tier2/catalog_di_test.go`.
   - Risk: not caused by Step 4.C, but the requested formatting validation is not globally clean.

2. The Step 4.C diff carries a whitespace error in a Step 4.B audit artifact.
   - Evidence: `git diff --check HEAD^..HEAD -- ...` reports `specs/SPEC-017-IMPL-STEP_4B-security-r4-audit.md:169: new blank line at EOF`.
   - Risk: non-runtime polish, but it makes the diff-check validation fail.

### INFO

- `stats_request_total`, `stats_partner_key_request_total`, `stats_rollup_lag_seconds`, `stats_rollup_errors_total`, and `stats_rate_limit_exceeded_total` are declared with the required Counter/Gauge types in `phase4-coordinator/internal/stats/metrics/metrics.go:58-92`.
- The Prometheus registry is coordinator-owned rather than the global default at `phase4-coordinator/cmd/coordinator/main.go:543-558`.
- `stats_request_served` is emitted inside the access-log middleware after the handler returns and includes `latency_ms` at `phase4-coordinator/internal/stats/middleware.go:176-184`.
- The request observability pointer seam lets handlers set `generated_at_age_ms` for the outer access middleware (`phase4-coordinator/internal/stats/auth.go:68-95`, `handlers.go:142-146`).
- `stats_handler_panic` remains inside recover middleware and logs only path/method/panic type at `phase4-coordinator/internal/stats/middleware.go:87-122`.
- `stats_rollup_drift_detected` includes component, axis, divergence_pct, rebuild_value, and incremental_value at `phase4-coordinator/internal/stats/rollup/rebuild.go:231-242`.
- Partner-key issue/revoke events do not include raw token or token_hash fields in their event maps (`phase4-coordinator/cmd/coordinator/partnerkeys.go:293-300`, `:434-438`).
- OPS.md includes the §6.6.2 sign-off template and explicitly marks production partner-key issuance as `NOT YET SATISFIED` at `OPS.md:725-742`.

## Category sweep

A. Event emitter wiring: FAIL HIGH. Emit sites exist, but `stats_rollup_tick_completed` can emit empty component and new event paths are untested.

B. Prometheus metric type + labels: FAIL HIGH. Types are correct, but auth-failure limiter 429s are labeled as public and nightly rebuild errors do not increment the error counter.

C. Field redaction: PASS by static field-set inspection for the Step 4.C additions. No raw token, 43-char body, token_hash bytes, or raw Authorization header are intentionally included in the new event maps/metric labels inspected.

D. OPS.md runbook entries: FAIL MEDIUM. Four entries exist plus sign-off template, but failure-recovery steps are incomplete.

E. CHANGELOG.md format: PASS with no blocking code-lane finding. The v0.1.8 entry cites PR #173 and lists the delivered API/metric/event surface.

F. AC-20 CI gate: PASS. `TestAC20_NoOperatorExactAuditRow` exists under the integration-tag stats suite (`phase4-coordinator/internal/stats/integration_test.go:448-476`), and `.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration` on PRs.

G. Metric-label hygiene test: FAIL MEDIUM. The test manually emits sample metric labels instead of driving the Step 3 mux and scraping production-derived labels.

H. End-of-impl AC sweep: FAIL HIGH. No Step 4.C convergence/AC-sweep file exists.

I. Test surface: FAIL HIGH/MEDIUM. Metric declaration tests pass, but production emitters for new events and multiple metrics are not driven and asserted.

## Final verdict

READY TO LOCK: NO
Blocking count: 0 CRITICAL / 5 HIGH / 3 MEDIUM
