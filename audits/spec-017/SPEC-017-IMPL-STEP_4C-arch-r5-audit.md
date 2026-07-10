# SPEC-017 IMPL Step 4.C - Architecture Audit Round 5

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `fef509c` (`impl(017): Step 4.C round-4 fixes - SPEC-shaped token + family-presence + CI scope + stale comment`)
Diff base checked: `022cd55` (Step 4.B tip)
Lens: ARCHITECTURE
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C

## Verdict

READY TO LOCK.

Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 15 INFO.

Round 4's remaining architecture blocker is closed. The wired metric-label
hygiene test now uses a SPEC-shaped 47-character `mpk_` token, asserts the
partner request succeeds with HTTP 200, requires all five metric families to
be present with samples, and scans label values for the seeded raw token, its
prefix, generic `mpk_`, bearer fragments, Origin fragments, `token_hash`, and
43-character token-body shape. The stale drift-comment LOW is also closed.

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
- All prior Step 4.C architecture audits r1-r4 and
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
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats ./cmd/coordinator`
  from `phase4-coordinator/` - local environment blocker before product
  assertions: testcontainers panicked with `rootless Docker not found`.

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

- Round 4 MEDIUM 1 is closed at
  `phase4-coordinator/internal/stats/step4c_integration_test.go:72-80`:
  the wired hygiene test now builds a SPEC-shaped 47-character token
  (`mpk_` + 43 base64url characters) and derives the seeded
  `partner_keys.prefix` from that same token.
- The same test now asserts the partner leaderboard request returns HTTP 200
  at `phase4-coordinator/internal/stats/step4c_integration_test.go:95-97`,
  so `stats_partner_key_request_total{partner_key_id}` is exercised on the
  successful partner path rather than merely after a failed/stale request.
- The wired hygiene test now requires all five metric families to be present
  with samples at `phase4-coordinator/internal/stats/step4c_integration_test.go:133-154`.
- The wired hygiene denylist now includes the actual seeded raw token, actual
  seeded prefix, and generic `mpk_` fragment at
  `phase4-coordinator/internal/stats/step4c_integration_test.go:156-180`.
- The five required Prometheus metric names remain the only `stats_*`
  metric declarations, all in
  `phase4-coordinator/internal/stats/metrics/metrics.go:62-95`.
- Production metric labels remain structurally bounded:
  `stats_request_total` uses closed endpoint/status/tier labels,
  `stats_partner_key_request_total` uses `strconv.FormatInt(pkid, 10)`, and
  429 counters use the same closed endpoint/tier vocabulary at
  `phase4-coordinator/internal/stats/middleware.go:211-222`.
- `stats_request_served` emits the locked request field set at
  `phase4-coordinator/internal/stats/middleware.go:194-201`.
- `stats_handler_panic` emits only `event`, `route`, and `request_id` at
  `phase4-coordinator/internal/stats/middleware.go:119-123`; stack and
  panic type remain on an untagged debug line.
- `stats_rollup_drift_detected` emits the locked Section 9.4 axis fields at
  `phase4-coordinator/internal/stats/rollup/rebuild.go:243-250`.
- Round 4 LOW 1 is closed by the reworded drift comment at
  `phase4-coordinator/internal/stats/rollup/rebuild.go:213-218`, which now
  states that `delta_ratio` is absent from the locked `stats_*` event and
  survives only on the debug-only triage line.
- `stats_rollup_tick_completed` emits `component`, `generated_at`, and
  `duration_ms` at `phase4-coordinator/internal/stats/rollup/runner.go:263-269`.
- `stats_partner_key_issued` emits after successful token delivery and omits
  raw token, prefix, token hash, and created_at at
  `phase4-coordinator/cmd/coordinator/partnerkeys.go:312-348`.
- `stats_partner_key_revoked` emits the locked `id`, `reason`, and `actor`
  fields at `phase4-coordinator/cmd/coordinator/partnerkeys.go:446-453`.
- AC-20 is wired into every-PR CI: `.github/workflows/ci.yml:174-187` runs
  `make test-coordinator-integration`, and `Makefile:22-23` now runs both
  `./internal/stats/...` and `./cmd/coordinator/...` integration packages.
- OPS.md and CHANGELOG satisfy the Step 4.C documentation surfaces:
  runbooks and disclosure/sign-off live at `OPS.md:623-770`; the v0.1.8
  changelog entry with PR references and locked API summary lives at
  `docs/network-stats-api/CHANGELOG.md:7-58`.

## Category Sweep

A. Structured-log events: PASS. All six required event names exist. The
daemon-side events use zerolog and the handler events sit behind the Step 3
redaction-context middleware; partner-key CLI events are structured JSON on
stderr with closed field maps and no raw token / prefix / token_hash fields.

B. Prometheus metric inventory and label hygiene: PASS. The inventory is the
five locked metric families only. Production labels are bounded to closed
sets or integer `partner_keys.id`, and the wired hygiene test now proves all
five families land before scanning every label value for forbidden substrings.

C. OPS.md runbook entries: PASS. Rotate, revoke, panic-restart-loop recovery,
and emergency visibility revert entries are present. The visibility revert
text states there is no operator exact-enable path and cross-references AC-20.

D. Section 6.6.2 disclosure obligation: PASS. OPS.md has the disclosure
section, blocking production-issuance gate, sign-off template, and NOT YET
annotation. The Step 4.C convergence file quotes the template and states live
production sign-off is not yet satisfied.

E. CHANGELOG.md v0.1.8 entry: PASS. The version header, PR references, SPEC
version, and locked API delta summary are present.

F. AC-20 CI assertion: PASS BY SOURCE/CI WIRING. The required SQL assertion is
present and the every-PR integration target now includes both the stats and
coordinator command integration packages. Local Docker-backed execution was
blocked by missing rootless Docker.

G. Metric-label hygiene test: PASS BY SOURCE. The wired test emits all five
metric families through production or production-adjacent seams, asserts every
family is gathered with samples, and scans labels for raw token, token body,
prefix, Authorization fragment, Origin fragment, `mpk_`, and `token_hash`.
Local execution was blocked only by the Docker/testcontainers environment.

H. End-of-implementation 22-AC sweep: PASS BY ARTIFACT. The Step 4.C
convergence file contains a 22-AC table with owner step, test path, and PASS
status for every AC including AC-22. I did not re-run the full Docker-backed
AC suite locally due to the testcontainers blocker noted above.

I. Cross-step bleed: PASS. The Round 5 delta is limited to the Step 4.C
hygiene test and a rollup drift comment, plus adding the prior audit files.
I did not find Step 3 handler semantic drift or Step 4.A CLI surface drift in
the Step 4.C diff.

## Final Recommendation

Architecture lane is ready to lock at 0 CRITICAL + 0 HIGH + 0 MEDIUM.
