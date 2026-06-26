# SPEC-017 IMPL Step 4.C - Code Audit Round 2

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `ed86d8b` (`impl(017): Step 4.C round-1 fixes`)
Diff base checked: `022cd55` (Step 4.B tip)
Auditor lane: CODE

Verdict: NOT READY TO LOCK -
0 CRITICAL + 2 HIGH + 2 MEDIUM + 1 LOW + 7 INFO

## Validation evidence

- Required reading completed: `CLAUDE.md`; `SPEC-017-network-stats-api.md`
  v0.1.8 focused on Sections 5.4.6, 5.6, 6.6.2, 8.5, 9.4, 9.5, 9.6,
  and AC-1..AC-22; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC
  matrix; Step 4.C r1 ARCH/CODE/SECURITY audits; current Step 4.C
  convergence record.
- Step 4.C diff scope:
  `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`.
- Event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `golangci-lint run ./...` from `phase4-coordinator/` - PASS (`0 issues`).
- Literal `gofmt -l ./...` from `phase4-coordinator/` - FAIL:
  `lstat ./...: no such file or directory` because gofmt does not accept
  package patterns. Equivalent file-based command
  `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l`
  reported `./internal/buyer/transport_result_test.go` and
  `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C diff.
- `make test-coordinator-integration` - FAIL before AC execution in this
  local environment: testcontainers panicked with `rootless Docker not
  found`. CI wiring for the same target remains present.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - FAIL: trailing whitespace in `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md`
  lines 3-5.

## Findings

### CRITICAL

None.

### HIGH

1. Partner-key and auth-failure observability context does not propagate back
   to the access-log middleware, so key metrics/events are mislabeled or never
   emitted.

   Evidence:
   - The access-log middleware creates a request with a parent context and
     later reads `partnerKeyIDFromContext(r.Context())` and
     `tierOverrideFromContext(r.Context())` from that same outer request after
     `next.ServeHTTP` returns (`phase4-coordinator/internal/stats/middleware.go:177`,
     `:188-221`).
   - The dispatcher sets `withTierOverrideContext` only on a local `r =
     r.WithContext(...)` before returning the auth-failure 429
     (`phase4-coordinator/internal/stats/mux.go:111-120`).
   - The dispatcher sets `withPartnerKeyIDContext` only on a local `r =
     r.WithContext(...)` after successful partner auth
     (`phase4-coordinator/internal/stats/mux.go:149-157`).
   - `http.Request.WithContext` returns a new request; assigning it to the
     local variable inside `dispatch` does not mutate the outer request held by
     `accessLogMiddleware`. The existing `generated_at_age_ms` path works
     because it uses a mutable pointer in context
     (`phase4-coordinator/internal/stats/auth.go:68-95`); `partner_key_id`
     and `tier_override` are immutable context values (`auth.go:52-66`,
     `:98-114`).

   Impact: valid partner requests are emitted as `partner_key_id=0`, counted
   as `stats_request_total{tier="public"}`, and do not increment
   `stats_partner_key_request_total{partner_key_id}`. Auth-failure limiter
   429s still reach `stats_rate_limit_exceeded_total` as `tier="public"`
   instead of `tier="auth_failure"`. This silently breaks the Step 4.C
   Prometheus and `stats_request_served` contract.

   Fix direction: put partner key id and tier override into the existing
   mutable request observability struct, or pass a shared pointer from the
   middleware to the dispatcher and read it after the handler returns. Add a
   wired test that proves a successful partner request increments
   `stats_partner_key_request_total{partner_key_id="<id>"}` and an auth-failure
   429 increments `stats_rate_limit_exceeded_total{tier="auth_failure"}`.

2. `stats_handler_panic` still emits a field outside the locked Step 4.C field
   set.

   Evidence:
   - BUILD Step 4.C locks `stats_handler_panic` to
     `(request_id, route - NO stack in public log, NO Authorization)`
     (`specs/BUILD_SPEC_017_IMPL_PROMPT.md:655`).
   - Current code emits `event`, `route`, `request_id`, and `panic_type`
     (`phase4-coordinator/internal/stats/middleware.go:122-127`).
   - The r2 test asserts route/request_id and absence of `_stack`, but does
     not reject the extra `panic_type` field
     (`phase4-coordinator/internal/stats/step4c_integration_test.go:138-166`).

   Impact: the stack event was removed, but the public structured event still
   drifts from the locked field set. Dashboards or log contracts built from the
   Step 4.C taxonomy can diverge silently.

   Fix direction: remove `panic_type` from `stats_handler_panic`, or update the
   controlling BUILD/SPEC contract before relying on it. Tighten the test to
   unmarshal the event JSON and assert the exact allowed key set.

### MEDIUM

1. The wired metric-label hygiene test does not emit all five required metric
   families through production paths.

   Evidence:
   - `TestStep4C_WiredMux_MetricLabelHygiene` drives three overview requests,
     one invalid-bearer leaderboard request, and one overview request with an
     Origin (`phase4-coordinator/internal/stats/step4c_integration_test.go:61-65`).
   - That exercise can emit `stats_request_total`, but it does not produce a
     valid partner request, a 429 rate-limit rejection, a rollup-lag gauge
     update, or a rollup error counter increment.
   - The package-level `TestLabelHygiene` manually emits all five metric
     vectors (`phase4-coordinator/internal/stats/metrics/metrics_test.go:45-55`),
     but that is synthetic and does not validate production label derivation.

   Impact: category G remains only partially proven. The exact propagation bug
   in HIGH 1 survived because no wired test asserts partner-key or
   auth-failure metric labels after a real request path.

   Fix direction: extend the wired test to seed a partner key and drive a
   successful partner request, drive enough invalid-bearer requests to hit the
   auth-failure limiter, invoke one rollup lag observation, and increment the
   rollup error metric through a real runner error path before gathering.

2. Several new Step 4.C emitters still lack direct "runs once and value lands"
   tests.

   Evidence:
   - `rg` over test files finds no test assertion for
     `stats_rollup_tick_completed`, `stats_partner_key_issued`, or
     `stats_partner_key_revoked`.
   - `stats_rollup_tick_completed` is emitted in `rollup.Runner.runOne`
     (`phase4-coordinator/internal/stats/rollup/runner.go:244-250`).
   - Partner key issue/revoke events are emitted from CLI success paths
     (`phase4-coordinator/cmd/coordinator/partnerkeys.go:296-301`,
     `:432-439`).
   - The new Step 4.C integration tests cover only `stats_request_served`,
     `stats_handler_panic`, and wired label scanning
     (`phase4-coordinator/internal/stats/step4c_integration_test.go:28-166`).

   Impact: category I requires every new event or metric emitter to run once
   and assert the value lands. Coverage is still partial.

   Fix direction: add focused tests for rollup tick success, partner-key issue,
   and partner-key revoke events. For CLI events, capture stderr, unmarshal the
   JSON line, assert the locked fields, and assert no raw token, 43-character
   body, `token_hash`, or `prefix`.

### LOW

1. The scoped Step 4.C diff fails whitespace validation in an audit artifact.

   Evidence: `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
   reports trailing whitespace at
   `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md:3`,
   `:4`, and `:5`.

   Risk: non-runtime, but the required diff hygiene check is not clean.

### INFO

- The Step 4.C convergence record now exists and quotes the OPS.md sign-off
  template with `NOT YET SATISFIED` production disclosure status
  (`specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:15-36`).
- The convergence record lists all 22 ACs with owner step and test locations
  (`specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:41-65`).
- The five required Prometheus metrics are declared with the required
  Counter/Gauge types (`phase4-coordinator/internal/stats/metrics/metrics.go:58-92`).
- Nightly rebuild error and panic paths now increment
  `stats_rollup_errors_total` for `leaderboard_30d` and `leaderboard_all`
  (`phase4-coordinator/internal/stats/rollup/runner.go:285-292`, `:312-320`).
- `stats_rollup_tick_completed` no longer emits an empty component for the
  scalar `rewards_populated` tick (`phase4-coordinator/internal/stats/rollup/runner.go:234-243`).
- OPS.md has the four requested runbook entries and each now includes an
  `If this fails` recovery block (`OPS.md:623-719`).
- CHANGELOG.md now carries per-step PR references, each citing #173 for this
  single-PR implementation (`docs/network-stats-api/CHANGELOG.md:33-45`).

## Category sweep

A. Event emitter wiring: FAIL HIGH/MEDIUM. Emit sites exist in the expected
surfaces, but `stats_request_served` cannot see partner-key id or auth-failure
tier context, `stats_handler_panic` still has field-set drift, and three new
event emitters lack direct tests.

B. Prometheus metric type + labels: FAIL HIGH. Metric types are correct, but
the access-log middleware cannot observe the child-context values set by
dispatch, so partner and auth-failure labels are wrong or absent in production.

C. Field redaction: PASS by inspected field maps and label definitions. No raw
token, 43-character body, `token_hash`, raw Authorization header value, or
secret byte-substring is intentionally emitted in the Step 4.C event/metric
fields reviewed. The remaining issues are correctness and coverage, not an
observed secret leak.

D. OPS.md runbook entries: PASS. Four runbook entries exist with invocation
commands, expected outcome, and failure recovery steps; the disclosure section
and sign-off template are present.

E. CHANGELOG.md format: PASS. The v0.1.8 entry has a Markdown version header,
bullet list, SPEC behavior summary, metrics/events list, and per-step PR
references.

F. AC-20 CI gate: PASS by source and CI wiring. The pure SQL count assertion is
`TestAC20_NoOperatorExactAuditRow` in
`phase4-coordinator/internal/stats/integration_test.go:448-475`, and
`.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration` on
PRs. Local execution was blocked by missing rootless Docker before AC execution.

G. Metric-label hygiene test: FAIL MEDIUM. A wired mux hygiene test exists, but
it does not emit all five metric families through production paths and does not
assert the partner/auth-failure labels that Step 4.C depends on.

H. End-of-impl AC sweep: PASS by artifact presence. The convergence file lists
AC-1 through AC-22 with owner step and test path. Local integration execution
could not validate the Docker-backed rows.

I. Test surface: FAIL MEDIUM. Default `go test ./...` passes, but direct
emitter tests are still missing for rollup tick completion and partner-key
issue/revoke events; production-path metric coverage remains partial.

## Final verdict

READY TO LOCK: NO
Blocking count: 0 CRITICAL / 2 HIGH / 2 MEDIUM
