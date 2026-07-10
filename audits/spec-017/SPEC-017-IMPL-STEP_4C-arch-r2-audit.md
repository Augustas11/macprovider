# SPEC-017 IMPL Step 4.C - Architecture Audit Round 2

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `ed86d8b` (`impl(017): Step 4.C round-1 fixes - 1C + 5H + 4M + 3L closures across all three lanes`)
Diff base checked: `022cd55` (Step 4.B tip)
Lens: ARCHITECTURE
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C

## Verdict

REQUEST CHANGES.

Blocking count: 0 CRITICAL / 0 HIGH / 3 MEDIUM / 1 LOW / 10 INFO.

Round 1's CRITICAL and HIGH architecture blockers are mostly closed: the
Step 4.C convergence file now exists, quotes the Section 6.6.2 sign-off
template, records SPEC-014 v0.9 as NOT YET satisfied for production
partner-key issuance, and the changelog now has per-step PR references.

The remaining architecture lock blockers are narrower observability-contract
drift: metric labels now admit values outside the prompt's closed vocabulary,
structured events still carry fields outside the locked Step 4.C field sets,
and the wired metric-hygiene test still does not emit all five metrics through
the real request/rollup paths.

## Required Reading And Validation

Required reading completed:

- `CLAUDE.md`.
- `specs/SPEC-017-network-stats-api.md` v0.1.8 focused on Sections 6.6.2,
  8.5, 9.4, 9.5, and 9.6.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C, including the
  v0.1.7-tightened Section 6.6.2 cutover gate, v11 ARCH r10 H1
  sign-off-template paragraph, and AC-15/AC-20 ownership matrix.
- `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
- `specs/SPEC-017-IMPL-STEP_4C-arch-r1-audit.md`.
- `specs/SPEC-017-IMPL-STEP_4C-code-r1-audit.md`.
- `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md`.
- `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md`.
- Step 4.A and Step 4.B architecture audit files available in this worktree.
  I did not find dedicated Step 4.A or Step 4.B convergence-record files under
  `specs/`; the Step 4.C convergence file references the Step 4.B audit-lock
  files instead.

Commands run:

- `git fetch origin` - PASS.
- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - scoped Step 4.C diff reviewed.
- Required event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Required metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- OPS.md scan for rotate, revoke, panic-restart-loop, emergency visibility
  revert, disclosure section, and sign-off template.
- `cat docs/network-stats-api/CHANGELOG.md`.
- `go test ./internal/stats/metrics` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/...` from `phase4-coordinator/` - PASS.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats`
  from `phase4-coordinator/` - NOT EXECUTED TO COMPLETION locally;
  testcontainers panicked with `rootless Docker not found` before assertions ran.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - FAIL: trailing whitespace in `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md`.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

1. Prometheus metric labels admit `tier="auth_failure"` and `endpoint=""`,
   violating the Step 4.C closed label vocabulary.

   Evidence:
   - BUILD Step 4.C requires `stats_request_total{endpoint,status,tier}` with
     `tier` limited to `"public"` or `"partner"`, and this audit prompt
     requires `endpoint` limited to `overview` / `leaderboard` / `health`.
   - `phase4-coordinator/internal/stats/metrics/metrics.go:17-20` still
     documents that same closed vocabulary.
   - `phase4-coordinator/internal/stats/mux.go:118` sets
     `withTierOverrideContext(..., "auth_failure")`.
   - `phase4-coordinator/internal/stats/middleware.go:213-221` forwards that
     override into both `stats_request_total` and
     `stats_rate_limit_exceeded_total`.
   - `phase4-coordinator/internal/stats/metrics/metrics.go:89` documents the
     rate-limit metric help as `public/partner/auth_failure`.
   - `phase4-coordinator/internal/stats/metrics/metrics_test.go:27-28`
     whitelists `auth_failure` for `tier` and `""` for `endpoint`.
   - `phase4-coordinator/internal/stats/handlers.go:738-748` returns `""` for
     unknown `/v1/stats/*` paths; the access-log middleware still emits metrics
     after the 404 path.

   Risk: Dashboards and alerts built against the locked Step 4.C label enums
   see an uncontracted tier and an empty endpoint. The test suite now enshrines
   those extra values instead of rejecting them, so the hygiene gate can pass
   while the public observability contract drifts.

   Fix: Keep `tier` labels to `public` / `partner` unless the SPEC and kickoff
   prompt are intentionally bumped. For auth-failure 429s, either classify the
   request under the locked public tier or introduce a separate explicitly
   contracted metric in a future version. Avoid emitting endpoint-labelled
   request/rate-limit metrics for unknown paths, or map them only after the
   contract is amended.

2. Structured-log events still carry fields outside the locked Step 4.C field
   sets, and the new tests encode the expanded contract.

   Evidence:
   - BUILD Step 4.C locks `stats_request_served` to
     `(endpoint, status, latency_ms, generated_at_age_ms,
     partner_key_id_or_null)`.
   - `phase4-coordinator/internal/stats/middleware.go:191-199` also emits
     `method`.
   - BUILD Step 4.C locks `stats_handler_panic` to `(request_id, route)`.
   - `phase4-coordinator/internal/stats/middleware.go:122-127` also emits
     `panic_type`.
   - `phase4-coordinator/internal/stats/step4c_integration_test.go:138-140`
     describes the locked panic field set as `route + request_id + panic_type`,
     which conflicts with the kickoff.
   - BUILD Step 4.C locks `stats_rollup_drift_detected` to
     `(component, axis, divergence_pct, rebuild_value, incremental_value)`.
   - `phase4-coordinator/internal/stats/rollup/rebuild.go:231-242` also emits
     `window`, `provider_id_sample`, `delta_ratio`, and `threshold`.

   Risk: The six-event taxonomy is present, but consumers cannot rely on the
   locked event schemas. The extra fields are not raw-token leaks, so this is
   not a CRITICAL issue, but it keeps the architecture contract ambiguous at
   the final observability lock point.

   Fix: Remove the extra fields from the `stats_*` structured events, or move
   them to non-`stats_*` debug/operator logs. Update tests so they assert the
   kickoff's closed field sets rather than the expanded ones.

3. The wired metric-label hygiene test still does not emit all five metrics
   under the real request/rollup paths.

   Evidence:
   - The prompt requires a metric-label hygiene test that emits all five
     metrics under test load and scans every label value for raw token,
     `token_hash`, prefix, Authorization fragment, and Origin fragment.
   - `phase4-coordinator/internal/stats/step4c_integration_test.go:28-90`
     drives real requests through `stats.NewMuxWithMetrics`, but the requests
     only exercise handler request counters. It does not seed a valid partner
     key, so `stats_partner_key_request_total{partner_key_id}` is not emitted
     through the wired path. It does not force a 429, so
     `stats_rate_limit_exceeded_total` is not emitted through the wired path.
     It also does not drive `stats_rollup_lag_seconds` or
     `stats_rollup_errors_total`.
   - `phase4-coordinator/internal/stats/metrics/metrics_test.go:40-57` emits
     all five metrics synthetically, but that bypasses the request, auth,
     limiter, and rollup code that can accidentally pass attacker-controlled
     values into labels.
   - The wired test sends `Authorization: Bearer garbage`, not a real-looking
     47-character `mpk_*` token with a 43-character body and prefix.

   Risk: The test suite proves the metrics package can be used safely in
   isolation, but it still does not prove the production wiring cannot leak
   token-derived, Authorization-derived, Origin-derived, or high-cardinality
   values into labels across the five required metrics.

   Fix: Extend the wired integration test to seed a valid partner key, send a
   real-looking `mpk_` token, drive a partner request, force a public or partner
   429, and trigger rollup lag/error metric updates against a fresh registry.
   Then scan the gathered label values for the full denylist and closed enum
   sets.

### LOW

1. The scoped diff still fails whitespace validation in a newly added Step 4.C
   audit artifact.

   Evidence:
   - `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
     reports trailing whitespace at:
     `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md:3`,
     `:4`, and `:5`.

   Risk: Non-functional, but this is part of the Step 4.C scoped diff and
   should be normalized before lock.

   Fix: Remove the trailing spaces.

### INFO

- The six required structured event names are present under
  `phase4-coordinator/`.
- Round 1's missing convergence-file blocker is closed by
  `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md`.
- The convergence file quotes the OPS.md sign-off template and records
  production SPEC-014 v0.9 disclosure status as NOT YET SATISFIED.
- OPS.md contains the four requested runbook entries at `OPS.md:623-719`.
- OPS.md states that emergency visibility revert hardcodes `bucketed` and that
  `visibility exact` hard-rejects at `OPS.md:703-710`.
- OPS.md contains the partner-key exact-dollar exposure disclosure, blocking
  production-issuance gate, sign-off template, and NOT YET annotation at
  `OPS.md:721-767`.
- The public changelog contains a v0.1.8 entry, cites SPEC-017 v0.1.8, lists
  API deltas, and now has a per-step PR table referencing PR #173.
- The five required metric names are declared in
  `phase4-coordinator/internal/stats/metrics/metrics.go:58-92`.
- Production uses a coordinator-owned Prometheus registry at
  `phase4-coordinator/cmd/coordinator/main.go:543-558`, so `/metrics` is not
  implicitly polluted by Go/process default collectors.
- AC-20 is wired into the every-PR integration job:
  `.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration`,
  and `phase4-coordinator/internal/stats/integration_test.go:448-475`
  contains the required zero-count assertion.

## Category Sweep

A. Structured-log events: FAIL WITH MEDIUM. All six event names exist, but
several event payloads still exceed the locked field sets. See MEDIUM 2.

B. Prometheus metric inventory and label hygiene: FAIL WITH MEDIUM. The five
metric names are declared and no extra custom `stats_*` metrics were found, but
the label values include uncontracted `tier="auth_failure"` and permit
`endpoint=""`. See MEDIUM 1.

C. OPS.md runbook entries: PASS. Rotate, revoke, panic-restart-loop recovery,
and emergency visibility revert entries are present. The visibility revert text
states there is no operator path to write exact mode and references the AC-20
assertion.

D. Section 6.6.2 disclosure obligation: PASS. OPS.md has the disclosure
section, blocking gate, sign-off template, and NOT YET annotation. The Step 4.C
convergence file quotes the template and states live production sign-off is not
yet satisfied.

E. CHANGELOG.md v0.1.8 entry: PASS. The version header, PR references, SPEC
version, and locked API delta summary are present.

F. AC-20 CI assertion: PASS BY SOURCE/CI WIRING. The test exists and is wired to
the CI integration job. Local execution was blocked by missing rootless Docker,
not by an assertion failure.

G. Metric-label hygiene test: FAIL WITH MEDIUM. The synthetic package test
emits all five metrics, and the wired test scans real request-path labels, but
no single wired test emits all five metrics through the real paths required by
the prompt. See MEDIUM 3.

H. End-of-implementation 22-AC sweep: PASS BY ARTIFACT. The Step 4.C
convergence file contains a 22-AC table with owner step, test path, and PASS
status for every AC including AC-22. I did not re-run the Docker-backed full
AC suite locally due the testcontainers blocker noted above.

I. Cross-step bleed: PASS. I did not find a Step 3 handler semantic change or
Step 4.A CLI command-surface change outside Step 4.C observability wiring. The
remaining issues are observability contract drift, not behavior changes to the
handler or CLI semantics.

## Final Recommendation

Do not lock Step 4.C yet. Close the metric label vocabulary drift, reduce the
structured `stats_*` event payloads to the locked field sets, and upgrade the
wired metric-label hygiene test so it emits all five metrics through the real
paths before the next architecture round.
