# SPEC-017 IMPL Step 4.C - Code Audit Round 5

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `fef509c` (`impl(017): Step 4.C round-4 fixes - SPEC-shaped token + family-presence + CI scope + stale comment`)
Diff base checked: `022cd55` (Step 4.B tip); round delta checked: `bb7c77e..fef509c`
Auditor lane: CODE

Verdict: READY TO LOCK -
0 CRITICAL + 0 HIGH + 0 MEDIUM + 0 LOW + 12 INFO

## Validation evidence

- Required reading completed: `CLAUDE.md`; `SPEC-017-network-stats-api.md`
  v0.1.8 sections 6.6.2, 8.5, 9.4, 9.5, 9.6, and AC-1..AC-22;
  `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC matrix; ARCH-lane
  Step 4.C prompt; Step 3 convergence record; Step 4.A / Step 4.B lock
  audits available in this worktree; Step 4.C ARCH/CODE r4 audits and
  convergence record.
- `git rev-parse --short HEAD` - `fef509c`.
- `git diff --name-status bb7c77e..HEAD` - round-4 closure delta is
  `Makefile`, `internal/stats/step4c_integration_test.go`,
  `internal/stats/rollup/rebuild.go`, plus prior r4 audit artifacts.
- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/
  specs/ Makefile .github/workflows/ci.yml` - scoped Step 4.C file list
  reviewed.
- Event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `golangci-lint run ./...` from `phase4-coordinator/` - PASS (`0 issues`).
- Literal `gofmt -l ./...` from `phase4-coordinator/` - FAIL because
  `gofmt` does not expand Go package globs (`lstat ./...: no such file or
  directory`). Equivalent file walk
  `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l`
  reports `./internal/buyer/transport_result_test.go` and
  `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C diff.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m
  ./internal/stats ./cmd/coordinator` - NOT EXECUTED TO COMPLETION locally;
  both packages panic before product assertions with `rootless Docker not
  found`.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/
  Makefile .github/workflows/ci.yml` - PASS.
- Manual OPS.md + changelog + sign-off-template scan completed.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

None.

### INFO

- Round-4 fixed CODE r4 M1 / ARCH r4 M1: the wired metric-label hygiene test
  now uses a SPEC-shaped token (`mpk_` + 43-character body), seeds provider
  token + ledger data, drives one real rollup tick, asserts the partner request
  returns 200, asserts all five required metric families have samples, and
  denies the raw token, prefix, generic `mpk_`, invalid bearer, Origin
  fragment, `Bearer `, and `token_hash`
  (`phase4-coordinator/internal/stats/step4c_integration_test.go:72-180`).
- Round-4 fixed CODE r4 M2: `make test-coordinator-integration` now runs both
  `./internal/stats/...` and `./cmd/coordinator/...`, and the CI job invokes
  that target (`Makefile:22-23`, `.github/workflows/ci.yml:186-187`).
- The partner-key issue/revoke event landing tests are now in the wired
  integration target and assert the expected success-boundary, field set, and
  redaction properties (`cmd/coordinator/partnerkeys_integration_test.go:884-997`).
- Round-4 fixed ARCH r4 L1: the stale `delta_ratio` comment now says
  `delta_ratio` was removed from the locked `stats_*` event and survives only
  on the untagged debug-only triage line
  (`internal/stats/rollup/rebuild.go:213-218`).
- The five required Prometheus metrics remain declared with the required
  Counter/Gauge types and label names
  (`internal/stats/metrics/metrics.go:62-95`).
- Production metric labels remain bounded by code inspection:
  `endpoint` skips unknown stats paths, `tier` is only `public` or `partner`,
  and `partner_key_id` is `strconv.FormatInt(pkid, 10)`
  (`internal/stats/middleware.go:187-222`).
- `stats_request_served` remains inside the access-log middleware and includes
  `endpoint`, `status`, `latency_ms`, `generated_at_age_ms`, and
  `partner_key_id` (`internal/stats/middleware.go:172-201`).
- `stats_handler_panic` remains behind the redaction-context layer and emits
  only `event`, `route`, and `request_id`; stack and panic type are on an
  untagged debug line (`internal/stats/mux.go:64-70`,
  `internal/stats/middleware.go:119-132`).
- `stats_rollup_tick_completed` and `stats_rollup_drift_detected` carry the
  locked field sets (`internal/stats/rollup/runner.go:263-269`,
  `internal/stats/rollup/rebuild.go:243-250`).
- `stats_partner_key_issued` and `stats_partner_key_revoked` are emitted only
  on successful CLI paths with the locked field sets and without raw token,
  prefix, or token hash (`cmd/coordinator/partnerkeys.go:293-349`,
  `cmd/coordinator/partnerkeys.go:446-455`).
- AC-20 remains a pure SQL zero-count assertion and is wired into the
  integration CI target (`internal/stats/integration_test.go:448-475`,
  `Makefile:22-23`, `.github/workflows/ci.yml:186-187`).
- OPS.md contains the four runbook entries with command, expected outcome, and
  failure recovery, plus the §6.6.2 disclosure gate and sign-off template;
  the changelog has the v0.1.8 entry and cites #173 for each delivered step
  (`OPS.md:615-770`, `docs/network-stats-api/CHANGELOG.md:7-58`).

## Category sweep

A. Event emitter wiring: PASS. All six required event names live in the
expected production surfaces: access-log middleware, recover middleware,
rollup runner/rebuild paths, and partner-key CLI success paths.

B. Prometheus metric type + labels: PASS. The five required metrics use the
required Counter/Gauge types and closed label names. Production label values
are bounded and do not include raw token, prefix, token hash, Authorization,
Origin, or label text.

C. Field redaction: PASS. Inspected event fields and metric labels do not
surface the raw token, 43-character token body, `token_hash`, raw
Authorization header, or secret-derived substrings.

D. OPS.md runbook entries: PASS. The four locked operational entries are
present with invocation command, expected outcome, and recovery steps if they
fail. The disclosure section and sign-off template are present with current
status marked NOT YET SATISFIED for production issuance.

E. CHANGELOG.md format: PASS. The v0.1.8 entry has a Markdown version header,
bullet list of locked behavior, SPEC version context, metrics/events list, and
per-step PR references citing #173 for this single-PR implementation.

F. AC-20 CI gate: PASS by source and CI wiring. Local execution is blocked by
missing rootless Docker before assertions run.

G. Metric-label hygiene test: PASS by source. The wired test now drives a real
request through the Step 3 mux, exercises all five metric families, asserts
the partner request returns 200, asserts all families landed, and scans all
label values for the required forbidden forms.

H. End-of-impl AC sweep: PASS by artifact. The convergence file lists AC-1
through AC-22 with owner step and test path, quotes the §6.6.2 sign-off
template, and states live production sign-off is not yet satisfied.

I. Test surface: PASS by source and CI wiring. Every new event or metric has a
landing assertion in default or integration-tag tests, and the integration CI
target now includes both `internal/stats` and `cmd/coordinator`.

## Round-4 closure checks

- CODE r4 M1 / ARCH r4 M1: CLOSED. The wired metric-label hygiene test now has
  a SPEC-shaped token, real partner success path, all-family presence
  assertion, and expanded denylist.
- CODE r4 M2: CLOSED. Partner-key issue/revoke event landing tests are wired
  into the PR integration target via `./cmd/coordinator/...`.
- ARCH r4 L1: CLOSED. The stale `delta_ratio` dashboard comment was reworded.

## Final verdict

READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 12 INFO
