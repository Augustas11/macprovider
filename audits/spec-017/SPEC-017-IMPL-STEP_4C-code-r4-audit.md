# SPEC-017 IMPL Step 4.C - Code Audit Round 4

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `bb7c77e` (`impl(017): Step 4.C round-3 fixes - close success-boundary + real-seam test gaps`)
Diff base checked: `022cd55` (Step 4.B tip); round delta checked: `6bc8270..bb7c77e`
Auditor lane: CODE

Verdict: NOT READY TO LOCK -
0 CRITICAL + 0 HIGH + 2 MEDIUM + 0 LOW + 10 INFO

## Validation evidence

- Required reading completed: `CLAUDE.md`; `SPEC-017-network-stats-api.md`
  v0.1.8 focused on Sections 6.6.2, 8.5, 9.4, 9.5, 9.6, and AC-1..AC-22;
  `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC matrix; Step 4.C
  ARCH/CODE r3 audits; Step 4.C convergence record.
- Step 4.C round delta:
  `git diff --name-only 6bc8270..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`.
- Event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `golangci-lint run ./...` from `phase4-coordinator/` - PASS (`0 issues`).
- Literal `gofmt -l ./...` from `phase4-coordinator/` - FAIL:
  `lstat ./...: no such file or directory`; equivalent file-based command
  `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l`
  reported `./internal/buyer/transport_result_test.go` and
  `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C diff.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats`
  - NOT EXECUTED TO COMPLETION locally; testcontainers panicked with
  `rootless Docker not found` before assertions ran.
- `go test -tags=integration -run 'TestStep4C_StatsPartnerKeyIssuedEvent|TestStep4C_StatsPartnerKeyRevokedEvent|TestAC17_IssueLockedSPECCommand|TestIssueJournalStreamSuppresses' -timeout 5m ./cmd/coordinator`
  - NOT EXECUTED TO COMPLETION locally for the same testcontainers Docker
  blocker.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - PASS.
- Manual OPS.md + changelog scan completed.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

1. The wired metric-label hygiene test still does not prove the locked
   `mpk_`/43-character-token denial or that every required metric family
   actually landed.

   Evidence:
   - The Step 4.C CODE prompt requires the wired hygiene test to drive a real
     request through the Step 3 mux, gather metrics, and assert every label
     value does not match `[A-Za-z0-9_-]{43}` and does not contain `mpk_`.
   - `TestStep4C_WiredMux_MetricLabelHygiene` now seeds a partner key and sends
     a real bearer request, but the token is
     `mpk_step4c_partner_secret_token` (`phase4-coordinator/internal/stats/step4c_integration_test.go:80`),
     not a 47-character SPEC-shaped `mpk_` token with a 43-character body.
   - The wired test's deny list is
     `{"mpk_garbage", "garbage", "evil.malibu.tech", "Bearer ", "token_hash"}`
     (`step4c_integration_test.go:130`). It does not include the actual
     seeded bearer token and does not include the general forbidden substring
     `mpk_`.
   - The partner request status is ignored at `step4c_integration_test.go:93`,
     and the post-gather assertion loop at `step4c_integration_test.go:125-147`
     scans only label values that exist. It does not assert that all five
     metric families, or specifically
     `stats_partner_key_request_total{partner_key_id="<id>"}`, were present.

   Impact: the production code currently labels metrics with bounded values,
   but the wired regression gate can pass if the partner request fails to emit
   a partner-key metric, or if a future regression places the non-SPEC-shaped
   `mpk_step4c_partner_secret_token` in a metric label. The package-level
   synthetic hygiene test does deny `mpk_`, but it bypasses the wired request,
   auth, limiter, and rollup paths that this test is meant to prove.

   Fix direction: use a SPEC-shaped generated token (`mpk_` + 43 base64url
   chars) in the wired test, include `mpk_` and the exact raw token in the
   wired deny list, assert the partner request returns 200, and assert gathered
   samples exist for all five required metric families with the expected
   bounded labels.

2. The new partner-key CLI event landing tests are not wired into default tests
   or the existing PR integration target.

   Evidence:
   - The round-3 fix added `TestStep4C_StatsPartnerKeyIssuedEvent` and
     `TestStep4C_StatsPartnerKeyRevokedEvent` in
     `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:884`
     and `:953`.
   - That file is behind `//go:build integration`
     (`partnerkeys_integration_test.go:1`), so the required default
     `go test ./...` does not compile or run those landing assertions.
   - The only PR integration target is
     `make test-coordinator-integration`, which runs
     `cd phase4-coordinator && go test -tags=integration -timeout 5m ./internal/stats/...`
     (`Makefile:22-23`).
   - The CI job at `.github/workflows/ci.yml:186-187` invokes that make target,
     so the `cmd/coordinator` integration tests containing the issue/revoke
     event assertions are outside the wired every-PR integration suite.

   Impact: the implementation now emits `stats_partner_key_issued` after
   successful stdout/file delivery and emits `stats_partner_key_revoked` after
   successful revoke, but the direct landing tests for those two Step 4.C
   events are not enforced by the default test command or the existing CI
   integration gate. Category I remains partial for two of the six event
   emitters.

   Fix direction: either move these event assertions into default non-Docker
   tests via a small fake DB/emitter seam, or expand the integration target/CI
   job to run the relevant `cmd/coordinator` integration tests under
   `-tags=integration`.

### LOW

None.

### INFO

- Round-3 fixed CODE r3 M1 in production code: `stats_partner_key_issued` is
  now emitted only after `--token-out` writes successfully or after the raw
  token is printed to stdout (`phase4-coordinator/cmd/coordinator/partnerkeys.go:328-349`).
- The JOURNAL_STREAM suppression path now exits without emitting
  `stats_partner_key_issued` (`partnerkeys.go:341-345`).
- The issue event field set is still limited to `id`, `label`, `created_by`,
  and `rotated_from_id`; no raw token, prefix, `created_at`, or `token_hash`
  field is emitted (`partnerkeys.go:312-319`).
- `stats_partner_key_revoked` remains on the successful revoke path with
  `id`, `reason`, and `actor` only (`partnerkeys.go:446-455`).
- `ObserveRollupLagOnce` now drives `stats_rollup_lag_seconds` through a real
  `stats_components_health` read path (`internal/stats/rollup/observer.go:26-55`).
- `observeRollupLag` in the coordinator now delegates to that same helper
  inside its 15s ticker (`cmd/coordinator/main.go:942-952`).
- `RunTickOnceForTest` exposes the production `Runner.runOne` path for tests,
  so rollup tick success/error metrics can be exercised without synthetic
  metric writes (`internal/stats/rollup/runner.go:147-166`).
- `stats_rollup_tick_completed` has a direct landing test through `runOne`,
  including the `component=""` skip path for `rewards_populated`
  (`internal/stats/step4c_integration_test.go:256-294`).
- The five required Prometheus metrics remain declared with the required
  Counter/Gauge types and label names (`internal/stats/metrics/metrics.go:59-97`).
- AC-20 remains present as a pure SQL count assertion and wired into the
  existing PR integration job (`internal/stats/integration_test.go:448-475`,
  `.github/workflows/ci.yml:167-187`).

## Category sweep

A. Event emitter wiring: PASS by production code, MEDIUM test-wiring gap for
CLI emitters. The six emit sites are in the expected packages and request /
panic / rollup events use the existing zerolog path; partner-key events are
minimal stderr JSON lines in the CLI success paths.

B. Prometheus metric type + labels: PASS by code. The five required metrics
use the required Counter/Gauge types and closed label names.

C. Field redaction: PASS by inspected emit fields. I found no raw token,
43-character body, `token_hash`, raw Authorization value, or secret substring
in Step 4.C production event/metric fields.

D. OPS.md runbook entries: PASS. Four runbook entries exist with invocation
command, expected outcome, and failure recovery. The disclosure section and
sign-off template are present.

E. CHANGELOG.md format: PASS. The v0.1.8 entry has a Markdown version header,
bullet list, SPEC version, metrics/events list, and a per-step PR table citing
#173 for this single-PR implementation.

F. AC-20 CI gate: PASS by source and CI wiring. Local integration execution was
blocked by missing rootless Docker before AC assertions ran.

G. Metric-label hygiene test: FAIL MEDIUM. The wired test now drives real
production seams, but its assertions do not deny general `mpk_`, do not use a
SPEC-shaped 43-character token body, and do not assert every metric family
landed in the gathered registry.

H. End-of-impl AC sweep: PASS by artifact. The convergence file lists AC-1
through AC-22 with owner step and test path, quotes the §6.6.2 sign-off
template, and states live production sign-off is not yet satisfied.

I. Test surface: FAIL MEDIUM. Default `go test ./...` passes, but the new
partner-key issue/revoke event landing tests are build-tagged and not included
in the existing PR integration target. Metric landing assertions are also
partial as described in MEDIUM 1.

## Final verdict

READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 2 MEDIUM
