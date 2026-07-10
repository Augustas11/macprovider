# SPEC-017 IMPL Step 4.C - Architecture Audit Round 3

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `6bc8270` (`impl(017): Step 4.C round-2 fixes - SECURITY r2 LOCKED; ARCH/CODE field-set + observability propagation`)
Diff base checked: `022cd55` (Step 4.B tip)
Lens: ARCHITECTURE
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C

## Verdict

REQUEST CHANGES.

Blocking count: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 12 INFO.

Round 2's metric-label vocabulary and structured-event field-set blockers are
closed in the production code. The remaining architecture blocker is test-shape:
the wired metric-label hygiene test still does not emit all five metric families
through the wired load it claims to exercise, because no valid partner-key
request is seeded and the rollup metrics are nudged directly.

## Required Reading And Validation

Required reading completed:

- `CLAUDE.md`.
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 6.6.2, 8.5, 9.4,
  9.5, 9.6, and AC-15/AC-20/AC-22.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C, including the
  v0.1.7-tightened Section 6.6.2 cutover gate, v11 ARCH r10 H1
  sign-off-template paragraph, and AC-15/AC-20 ownership matrix.
- `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
- `specs/SPEC-017-IMPL-STEP_4C-arch-r1-audit.md`.
- `specs/SPEC-017-IMPL-STEP_4C-arch-r2-audit.md`.
- `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md`.
- Prior Step 4.C code/security audit files. Dedicated Step 4.A / Step 4.B
  convergence files are still not present under `specs/`; the Step 4.C
  convergence artifact references the Step 4.B audit-lock files instead.

Commands run:

- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - scoped Step 4.C diff reviewed.
- Required event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Required metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- OPS.md scan for rotate, revoke, panic-restart-loop, emergency visibility
  revert, disclosure section, and sign-off template.
- `cat docs/network-stats-api/CHANGELOG.md`.
- `go test ./internal/stats/metrics ./internal/stats/...` from
  `phase4-coordinator/` - PASS.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats`
  from `phase4-coordinator/` - NOT EXECUTED TO COMPLETION locally;
  testcontainers panicked with `rootless Docker not found` before assertions ran.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - PASS.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

1. The wired metric-label hygiene test still does not emit all five metrics
   under wired test load.

   Evidence:
   - BUILD Step 4.C requires metric-label hygiene coverage that emits all five
     metrics under test load and scans every label value for raw token,
     `token_hash`, prefix, Authorization fragment, and Origin fragment.
   - `phase4-coordinator/internal/stats/step4c_integration_test.go:61-65`
     drives overview requests, one invalid leaderboard bearer, and an
     Origin-bearing overview request.
   - `phase4-coordinator/internal/stats/step4c_integration_test.go:71-80`
     forces public rate-limit samples and then directly calls
     `m.RollupLagSeconds.WithLabelValues(...)` and
     `m.RollupErrorsTotal.WithLabelValues(...)`; those two samples are not
     emitted by the rollup observer / runner path in this test.
   - No valid `partner_keys` row is seeded in
     `TestStep4C_WiredMux_MetricLabelHygiene`; the only authorization value is
     `"garbage"` at line 64. Therefore the request path never sets a non-zero
     `partner_keys.id`, and `stats_partner_key_request_total{partner_key_id}`
     is not emitted by `middleware.go:217-219`.
   - The package-level test does synthesize
     `stats_partner_key_request_total` and all other metrics at
     `metrics/metrics_test.go:45-55`, but it bypasses the request/auth/limiter
     and rollup paths that the wired hygiene gate is meant to protect.

   Risk: The final AC-15 metric-label gate can pass while the production
   wiring has never proven that a real partner-key request emits only integer
   `partner_key_id` labels, and while rollup label samples are still synthetic
   inside the hygiene test. This leaves the principal Step 4.C architectural
   risk partly unexercised.

   Fix: Extend `TestStep4C_WiredMux_MetricLabelHygiene` or add a sibling
   integration test that seeds a valid `partner_keys` row, sends a real-looking
   47-character `mpk_*` token through `/v1/stats/leaderboard`, emits
   `stats_partner_key_request_total` from middleware, forces a 429, and drives
   rollup lag/error samples through the production observer/runner seams before
   gathering the registry. Keep the full denylist scan over every gathered
   label value.

### LOW

1. Test/convergence prose still carries stale round-2 vocabulary after the
   code reverted to the locked labels.

   Evidence:
   - `phase4-coordinator/internal/stats/metrics/metrics_test.go:13` still says
     `tier in {public, partner, auth_failure}`, while the actual allowlist at
     lines 25-28 correctly permits only `public` and `partner`.
   - `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:88-90` records
     `tierOverrideKey` / `auth_failure` as a closed CODE finding, but the
     current implementation deliberately labels auth-failure 429s as
     `tier="public"` per `phase4-coordinator/internal/stats/mux.go:106-119`.
   - The same convergence record still says the panic event includes
     `panic_type` at lines 76-80, but the current code emits only `route` and
     `request_id` at `middleware.go:119-123`.

   Risk: Non-functional, but stale audit/convergence prose makes the
   observability contract harder to audit in later rounds.

   Fix: Update comments and the convergence record after closing the remaining
   blocker so the final artifact matches the locked Step 4.C behavior.

### INFO

- The five required Prometheus metric names are declared in
  `phase4-coordinator/internal/stats/metrics/metrics.go:64-92`.
- Metric label vocabulary is now closed in production: `tier` is derived only
  as `public` or `partner` in `middleware.go:211-221`.
- Unknown `/v1/stats/*` paths no longer pollute metric endpoint labels because
  metrics are skipped when `endpoint == ""` in `middleware.go:211`.
- `stats_partner_key_request_total` is incremented only when a non-zero
  matched `partner_keys.id` is present, and the label is
  `strconv.FormatInt(pkid, 10)` in `middleware.go:217-219`.
- `stats_handler_panic` now emits only `event`, `route`, and `request_id` at
  `middleware.go:119-123`; stack and `panic_type` moved to an untagged debug
  line.
- `stats_request_served` no longer emits `method`; the event payload is the
  locked request-observability field set at `middleware.go:194-201`.
- `stats_rollup_drift_detected` now emits only `component`, `axis`,
  `divergence_pct`, `rebuild_value`, and `incremental_value` at
  `rollup/rebuild.go:237-244`.
- OPS.md contains the four required runbook entries at `OPS.md:623-719`.
- OPS.md states the emergency visibility CLI hardcodes bucketed mode and that
  `visibility exact` hard-rejects at `OPS.md:703-710`.
- OPS.md contains the Section 6.6.2 disclosure obligation, cutover gate,
  verbatim sign-off template, and NOT YET annotation at `OPS.md:721-770`.
- CHANGELOG.md has the v0.1.8 entry, SPEC version context, locked API delta
  summary, and per-step PR references at
  `docs/network-stats-api/CHANGELOG.md:7-58`.
- AC-20 is wired into the every-PR integration job:
  `.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration`,
  and `phase4-coordinator/internal/stats/integration_test.go:448-475` contains
  the required zero-count SQL assertion.

## Category Sweep

A. Structured-log events: PASS. All six event names exist. The production
payloads for request-served, panic, drift, tick-completed, key-issued, and
key-revoked are now limited to the locked field sets or carry only the allowed
partner-key id/label/actor fields. Debug detail is untagged rather than part of
the `stats_*` taxonomy.

B. Prometheus metric inventory and label hygiene: PASS inventory, MEDIUM test
gap. The five required metric names exist and I did not find extra custom
`stats_*` metrics. Production request-path labels are structurally bounded, but
the wired hygiene test still does not produce all five families through wired
load.

C. OPS.md runbook entries: PASS. Rotate, revoke, panic-restart-loop recovery,
and emergency visibility revert entries are present. The visibility revert text
states there is no operator exact-enable path and cross-references the AC-20
assertion.

D. Section 6.6.2 disclosure obligation: PASS. OPS.md has the disclosure
section, blocking production-issuance gate, sign-off template, and NOT YET
annotation. The Step 4.C convergence file quotes the template and states live
production sign-off is not yet satisfied.

E. CHANGELOG.md v0.1.8 entry: PASS. The version header, PR references, SPEC
version, and locked API delta summary are present.

F. AC-20 CI assertion: PASS BY SOURCE/CI WIRING. The required SQL assertion is
present and wired into the PR integration job. Local Docker-backed execution was
blocked by missing rootless Docker.

G. Metric-label hygiene test: FAIL WITH MEDIUM. The package-level synthetic
test emits all five metrics, and the wired test scans real request-path labels,
but the wired test still does not emit all five required metric families under
wired load. See MEDIUM 1.

H. End-of-implementation 22-AC sweep: PASS BY ARTIFACT. The Step 4.C
convergence file contains a 22-AC table with owner step, test path, and PASS
status for every AC including AC-22. I did not re-run the full Docker-backed AC
suite locally due to the testcontainers blocker noted above.

I. Cross-step bleed: PASS. I did not find a Step 3 handler semantic change or
Step 4.A CLI command-surface change outside Step 4.C observability wiring. The
remaining blocker is a Step 4.C test-coverage shape issue, not a behavior
change to handler or CLI semantics.

## Final Recommendation

Do not lock Step 4.C yet. Close the wired metric-label hygiene test gap so all
five required metric families, especially `stats_partner_key_request_total`, are
emitted under wired load before the next architecture round.
