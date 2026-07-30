# SPEC-017 IMPL Step 4.C - Architecture Audit Round 4

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `bb7c77e` (`impl(017): Step 4.C round-3 fixes - close success-boundary + real-seam test gaps`)
Diff base checked: `022cd55` (Step 4.B tip)
Lens: ARCHITECTURE
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C

## Verdict

REQUEST CHANGES.

Blocking count: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 13 INFO.

Round 3's production-path gap is mostly closed: the wired hygiene test now
seeds a real `partner_keys` row, sends a Bearer request through
`stats.NewMuxWithMetrics`, drives public rate-limit metrics through the
in-process limiter, drives rollup lag through `ObserveRollupLagOnce`, and
drives rollup errors through `Runner.runOne` via `RunTickOnceForTest`.

The remaining architecture blocker is that the hygiene gate still is not a
complete guard for the locked forbidden-label set. It scans for the invalid
`garbage` bearer, Origin, `Bearer `, and `token_hash`, but it does not scan for
the valid raw token it seeded or the seeded `mpk_step` prefix, and it does not
assert that all five metric families were actually gathered.

## Required Reading And Validation

Required reading completed:

- `CLAUDE.md`.
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 6.6.2, 8.5, 9.4,
  9.5, 9.6, and AC-15/AC-20/AC-22.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C, including the
  v0.1.7-tightened Section 6.6.2 cutover gate, v11 ARCH r10 H1
  sign-off-template paragraph, and AC-15/AC-20 ownership matrix.
- `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
- Step 4.A and Step 4.B final lock records available in this worktree:
  `SPEC-017-IMPL-STEP_4A-arch-r2-audit.md`,
  `SPEC-017-IMPL-STEP_4B-arch-r3-audit.md`,
  `SPEC-017-IMPL-STEP_4B-code-r4-audit.md`, and
  `SPEC-017-IMPL-STEP_4B-security-r4-audit.md`. Dedicated Step 4.A / 4.B
  convergence files are not present; the Step 4.C convergence file references
  the Step 4.B lock audit files.
- Prior Step 4.C architecture audits r1-r3 and
  `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md`.

Commands run:

- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - scoped Step 4.C diff reviewed.
- Required event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Required metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- OPS.md scan for rotate, revoke, panic-restart-loop, emergency visibility
  revert, disclosure section, sign-off template, and NOT YET status.
- `cat docs/network-stats-api/CHANGELOG.md`.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - PASS.
- `go test ./cmd/coordinator/... ./internal/stats/metrics ./internal/stats/...`
  from `phase4-coordinator/` - PASS.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats`
  from `phase4-coordinator/` - NOT EXECUTED TO COMPLETION locally;
  testcontainers panicked before product assertions with `rootless Docker not
  found`.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

1. The wired metric-label hygiene gate still does not scan for the actual
   valid token/prefix it seeds, and it does not prove all five metric families
   were gathered.

   Evidence:
   - BUILD Step 4.C requires the metric-label hygiene test to emit all five
     metrics under test load and scan every label value for raw token,
     `token_hash`, prefix, Authorization fragment, and Origin fragment.
   - `phase4-coordinator/internal/stats/step4c_integration_test.go:80-85`
     seeds a real partner key using raw token
     `mpk_step4c_partner_secret_token` and prefix `mpk_step`, then line 93
     sends that Bearer through the real leaderboard path.
   - The wired label denylist at
     `phase4-coordinator/internal/stats/step4c_integration_test.go:129-144`
     checks the 43-character body shape, `mpk_garbage`, `garbage`,
     `evil.streamvc.live`, `Bearer `, and `token_hash`; it does not include
     the actual raw token `mpk_step4c_partner_secret_token`, the actual prefix
     `mpk_step`, or a generic `mpk_` prefix fragment.
   - The same test gathers the registry at lines 125-128 and scans labels, but
     it never asserts that the gathered family names include
     `stats_request_total`, `stats_partner_key_request_total`,
     `stats_rollup_lag_seconds`, `stats_rollup_errors_total`, and
     `stats_rate_limit_exceeded_total`.
   - The synthetic package test at
     `phase4-coordinator/internal/stats/metrics/metrics_test.go:40-107`
     does check generic `mpk_` and integer `partner_key_id`, but it bypasses
     the production request/auth/limiter/rollup paths that the wired hygiene
     gate is supposed to protect.

   Risk: A future regression that labels
   `stats_partner_key_request_total{partner_key_id}` with the matched
   `partner_keys.prefix` could still pass the wired test when the prefix is
   `mpk_step`, because that forbidden value is not in the wired denylist. A
   regression that stops emitting one of the five families could also pass
   because the scan is over whatever was gathered, not the required inventory.

   Fix: In `TestStep4C_WiredMux_MetricLabelHygiene`, add the seeded raw token,
   seeded prefix, and generic `mpk_` to the denylist; after `reg.Gather()`,
   assert that all five required metric family names are present with at least
   one sample before scanning label values. Keep the synthetic package test as
   the closed-enum unit check.

### LOW

1. A rebuild comment still suggests `delta_ratio` is retained for dashboard
   compatibility even though the locked `stats_*` event moved it out of the
   public taxonomy.

   Evidence:
   - `phase4-coordinator/internal/stats/rollup/rebuild.go:205-212` says
     `divergence_pct` is `ratio * 100` and that legacy `delta_ratio` is kept
     for backward compatibility.
   - The actual locked event at
     `phase4-coordinator/internal/stats/rollup/rebuild.go:237-244` emits only
     `component`, `axis`, `divergence_pct`, `rebuild_value`, and
     `incremental_value`.
   - `delta_ratio` now appears only on the untagged debug detail line at
     `phase4-coordinator/internal/stats/rollup/rebuild.go:245-252`.

   Risk: Non-functional, but the comment can mislead future dashboard authors
   into expecting `delta_ratio` on `event=stats_rollup_drift_detected`.

   Fix: Reword the comment to say `delta_ratio` was removed from the locked
   `stats_*` event and exists only on the debug-only untagged triage line.

### INFO

- The five required Prometheus metric names are declared in
  `phase4-coordinator/internal/stats/metrics/metrics.go:64-95`.
- Production metric labels remain structurally bounded: endpoint metrics skip
  unknown `/v1/stats/*` paths, `tier` is derived only as `public` or `partner`,
  and `partner_key_id` is emitted with `strconv.FormatInt(pkid, 10)` in
  `phase4-coordinator/internal/stats/middleware.go:211-221`.
- `stats_request_served` emits the locked request field set at
  `phase4-coordinator/internal/stats/middleware.go:194-201`.
- `stats_handler_panic` emits only `event`, `route`, and `request_id` at
  `phase4-coordinator/internal/stats/middleware.go:119-123`; stack and
  `panic_type` are untagged debug detail.
- `stats_rollup_drift_detected` emits the locked Section 9.4 axis fields at
  `phase4-coordinator/internal/stats/rollup/rebuild.go:237-244`.
- `stats_rollup_tick_completed` emits `component`, `generated_at`, and
  `duration_ms` at `phase4-coordinator/internal/stats/rollup/runner.go:263-269`.
- `stats_partner_key_issued` now emits after successful raw-token delivery and
  omits raw token, prefix, token hash, and created_at at
  `phase4-coordinator/cmd/coordinator/partnerkeys.go:293-319`.
- `stats_partner_key_revoked` emits the locked `id`, `reason`, and `actor`
  fields at `phase4-coordinator/cmd/coordinator/partnerkeys.go:446-453`.
- OPS.md contains rotate, revoke, panic-restart-loop, and emergency
  visibility-revert runbooks at `OPS.md:623-719`.
- OPS.md states the emergency visibility CLI has no operator exact-enable path
  and that `coordinator visibility exact ...` hard-rejects at `OPS.md:703-711`.
- OPS.md contains the Section 6.6.2 disclosure obligation, production issuance
  gate, verbatim sign-off template, and NOT YET annotation at `OPS.md:721-770`.
- CHANGELOG.md has the v0.1.8 entry, SPEC version context, locked API delta
  summary, and per-step PR references at
  `docs/network-stats-api/CHANGELOG.md:7-58`.
- AC-20 is wired into the every-PR integration job:
  `.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration`,
  and `phase4-coordinator/internal/stats/integration_test.go:448-475` contains
  the required zero-count SQL assertion.

## Category Sweep

A. Structured-log events: PASS. All six required event names exist. Production
payloads for request-served, panic, drift, tick-completed, key-issued, and
key-revoked are limited to the locked field sets or global log metadata.

B. Prometheus metric inventory and label hygiene: PASS inventory, MEDIUM test
gap. The production label values are bounded by code inspection, but the wired
hygiene gate does not yet scan for the actual valid token/prefix and does not
assert that all five families were gathered. See MEDIUM 1.

C. OPS.md runbook entries: PASS. Rotate, revoke, panic-restart-loop recovery,
and emergency visibility revert entries are present. The visibility revert text
states there is no operator exact-enable path and cross-references AC-20.

D. Section 6.6.2 disclosure obligation: PASS. OPS.md has the disclosure
section, blocking production-issuance gate, sign-off template, and NOT YET
annotation. The Step 4.C convergence file quotes the template and states live
production sign-off is not yet satisfied.

E. CHANGELOG.md v0.1.8 entry: PASS. The version header, PR references, SPEC
version, and locked API delta summary are present.

F. AC-20 CI assertion: PASS BY SOURCE/CI WIRING. The required SQL assertion is
present and wired into the PR integration job. Local Docker-backed execution
was blocked by missing rootless Docker.

G. Metric-label hygiene test: FAIL WITH MEDIUM. The test now drives real
production paths for all five families, but the actual valid token/prefix
denylist and family-presence assertions are still missing. See MEDIUM 1.

H. End-of-implementation 22-AC sweep: PASS BY ARTIFACT. The Step 4.C
convergence file contains a 22-AC table with owner step, test path, and PASS
status for every AC including AC-22. I did not re-run the full Docker-backed AC
suite locally due to the testcontainers blocker noted above.

I. Cross-step bleed: PASS. I did not find a Step 3 handler semantic change or
Step 4.A CLI command-surface change outside Step 4.C observability wiring. The
remaining blocker is a Step 4.C metric-label test-gate issue.

## Final Recommendation

Do not lock Step 4.C yet. Close the wired metric-label hygiene gate by scanning
for the actual valid raw token and prefix and by asserting all five required
metric families are present in the gathered registry before the next
architecture round.
