# SPEC-017 IMPL Step 4.C - Code Audit Round 3

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `6bc8270` (`impl(017): Step 4.C round-2 fixes - SECURITY r2 LOCKED; ARCH/CODE field-set + observability propagation`)
Diff base checked: `022cd55` (Step 4.B tip)
Auditor lane: CODE

Verdict: NOT READY TO LOCK -
0 CRITICAL + 0 HIGH + 3 MEDIUM + 2 LOW + 9 INFO

## Validation evidence

- Required reading completed: `CLAUDE.md`; `SPEC-017-network-stats-api.md`
  v0.1.8 focused on Sections 6.6.2, 8.5, 9.4, 9.5, 9.6, and AC-1..AC-22;
  `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC matrix; Step 4.C
  ARCH/CODE/SECURITY r1-r2 audits; Step 4.C convergence record.
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
  `lstat ./...: no such file or directory`; equivalent file-based command
  `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l`
  reported `./internal/buyer/transport_result_test.go` and
  `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C diff.
- `go test -tags=integration -run 'TestStep4C|TestAC20' -timeout 5m ./internal/stats`
  - NOT EXECUTED TO COMPLETION locally; testcontainers panicked with
  `rootless Docker not found` before assertions ran.
- `go test -tags=integration -run 'TestAC17_IssueLockedSPECCommand|TestRotationOverlap|TestRevokeNonexistent' -timeout 5m ./cmd/coordinator`
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

1. `stats_partner_key_issued` is emitted before the CLI subcommand reaches its
   success boundary.

   Evidence:
   - The Step 4.C code prompt places `stats_partner_key_issued` in the CLI
     subcommand success path.
   - Current code emits the event immediately after the DB insert at
     `phase4-coordinator/cmd/coordinator/partnerkeys.go:296`.
   - The command can still return non-zero afterward if `--token-out` file
     writing fails (`partnerkeys.go:316-323`) or if `JOURNAL_STREAM` is set
     and the raw token is intentionally suppressed (`partnerkeys.go:328-332`).

   Impact: an operator/log consumer can see `stats_partner_key_issued` for a
   command invocation that ultimately failed and left an orphan row requiring
   revocation. That is not a secret leak, and the row does exist in
   `partner_keys`, but it violates the requested success-path wiring and makes
   event-driven audits overcount successfully delivered keys.

   Fix direction: emit `stats_partner_key_issued` only after the raw token has
   either been written to `--token-out` successfully or printed to interactive
   stdout. For the orphaned-row branches, emit a distinct non-`stats_*`
   operator diagnostic or include no Step 4.C success event.

2. The wired metric-label hygiene test still does not prove production-path
   labels for all required metric families.

   Evidence:
   - `TestStep4C_WiredMux_MetricLabelHygiene` drives real requests for public
     overview, invalid-bearer leaderboard, and public rate limiting
     (`phase4-coordinator/internal/stats/step4c_integration_test.go:61-73`).
   - It does not seed a valid partner key or send a successful partner request,
     so `stats_partner_key_request_total{partner_key_id}` is not emitted
     through the real auth dispatcher / access-log path.
   - It manually nudges `stats_rollup_lag_seconds` and
     `stats_rollup_errors_total` (`step4c_integration_test.go:74-80`) instead
     of driving `observeRollupLag` or a rollup runner error path.
   - The package-level `TestLabelHygiene` emits all five metrics synthetically
     (`phase4-coordinator/internal/stats/metrics/metrics_test.go:40-57`), but
     it bypasses the production request, auth, limiter, and rollup code.

   Impact: the round-2 context-propagation fix is plausible in code
   (`requestObs.PartnerKeyID` is mutable and read by the outer middleware), but
   no test proves a real partner request increments
   `stats_partner_key_request_total` with the decimal `partner_keys.id` label.
   Category G and category I remain partial.

   Fix direction: extend the integration test to insert a valid partner key,
   send a real `Authorization: Bearer mpk_<43-char-body>` leaderboard request,
   and assert gathered samples include
   `stats_partner_key_request_total{partner_key_id="<id>"}`. Add a small
   seam or targeted test for `observeRollupLag`, and drive a rollup error path
   with a real `rollup.Runner` metrics handle.

3. Several new Step 4.C event emitters still lack direct "runs once and value
   lands" assertions.

   Evidence:
   - Test search found no assertion for `stats_rollup_tick_completed`,
     `stats_partner_key_issued`, or `stats_partner_key_revoked` in test files.
   - `stats_rollup_tick_completed` is emitted at
     `phase4-coordinator/internal/stats/rollup/runner.go:245-250`.
   - Partner-key issue/revoke events are emitted at
     `phase4-coordinator/cmd/coordinator/partnerkeys.go:296-301` and
     `partnerkeys.go:435-439`.
   - Existing Step 4.C tests cover `stats_request_served`,
     `stats_handler_panic`, and partial metric hygiene only
     (`phase4-coordinator/internal/stats/step4c_integration_test.go:33-206`).

   Impact: default `go test ./...` passes, but category I requires every new
   emitter to run once and assert the value lands. Missing direct assertions
   let success-boundary drift like MEDIUM 1 survive.

   Fix direction: add focused tests that capture the rollup runner logger and
   CLI stderr, unmarshal the event line, and assert event name, required
   fields, forbidden fields/substrings, and success/failure boundaries.

### LOW

1. The Step 4.C convergence record is stale after round-2 fixes.

   Evidence:
   - `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:78-80` still says the
     panic event is closed with `route + request_id + panic_type`, but current
     code removed `panic_type` from the `stats_handler_panic` event
     (`phase4-coordinator/internal/stats/middleware.go:119-123`).
   - `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:97-100` still says
     auth-failure 429s are tagged as `tier="auth_failure"`, but current code
     deliberately reverted that metric label to the closed `public`/`partner`
     tier set (`phase4-coordinator/internal/stats/mux.go:111-122`).

   Risk: Non-runtime, but this is the end-of-implementation convergence
   artifact auditors will use to decide whether Step 4.C locked. It should not
   preserve closure text that contradicts the code.

2. `metrics_test.go` has a stale comment saying `auth_failure` is an allowed
   tier.

   Evidence: `phase4-coordinator/internal/stats/metrics/metrics_test.go:13`
   still says `tier in {public, partner, auth_failure}`, while the actual
   allowlist at `metrics_test.go:27` correctly permits only `public` and
   `partner`.

   Risk: Comment-only drift. The executable assertion is correct.

### INFO

- Round-2 fixed the prior production context propagation bug by moving the
  partner key id into the mutable per-request observability struct
  (`phase4-coordinator/internal/stats/auth.go:52-82`) and writing it from the
  dispatcher (`phase4-coordinator/internal/stats/mux.go:149-163`).
- `stats_handler_panic` now emits only `event`, `route`, and `request_id` as
  event-specific fields (`phase4-coordinator/internal/stats/middleware.go:119-123`).
- `stats_request_served` now omits the previous extra `method` field and keeps
  `endpoint`, `status`, `latency_ms`, `generated_at_age_ms`, and
  `partner_key_id` (`phase4-coordinator/internal/stats/middleware.go:194-201`).
- `stats_rollup_drift_detected` now includes the four required §9.4 axes plus
  component, with triage-only details moved to an untagged debug line
  (`phase4-coordinator/internal/stats/rollup/rebuild.go:237-252`).
- The five required Prometheus metrics are declared with the required
  Counter/Gauge types and label names (`phase4-coordinator/internal/stats/metrics/metrics.go:59-97`).
- Metrics for unknown `/v1/stats/*` paths are now skipped, preventing
  `endpoint=""` samples (`phase4-coordinator/internal/stats/middleware.go:206-223`).
- `tier="auth_failure"` has been removed from the executable label allowlist
  (`phase4-coordinator/internal/stats/metrics/metrics_test.go:27`).
- OPS.md contains the four requested runbook entries, each with command,
  expected outcome, and `If this fails` recovery text (`OPS.md:623-719`).
- AC-20 is present as a pure SQL count assertion and wired into the existing
  PR integration job (`phase4-coordinator/internal/stats/integration_test.go:448-475`,
  `.github/workflows/ci.yml:167-187`).

## Category sweep

A. Event emitter wiring: FAIL MEDIUM. Runtime request/rollup/panic emit sites
are in the expected packages and field-set drift from r2 is fixed, but
`stats_partner_key_issued` fires before the issue command's success boundary
and several emitters still lack direct landing assertions.

B. Prometheus metric type + labels: PASS by code. Metric types and label names
match the prompt. `partner_key_id` is decimal `partner_keys.id`, endpoint is
closed to the three route tokens for metric emission, and tier is closed to
`public` / `partner`.

C. Field redaction: PASS by inspected field maps. I found no raw token,
43-character body, `token_hash`, raw Authorization value, or secret substring
in the reviewed Step 4.C event or metric fields.

D. OPS.md runbook entries: PASS. Four entries exist with invocation command,
expected outcome, and failure recovery. The disclosure section and sign-off
template are present.

E. CHANGELOG.md format: PASS. The v0.1.8 entry has a Markdown version header,
bullet list, SPEC version, metrics/events list, and a per-step PR table citing
#173 for this single-PR implementation.

F. AC-20 CI gate: PASS by source and CI wiring. Local integration execution was
blocked by missing rootless Docker before AC assertions ran.

G. Metric-label hygiene test: FAIL MEDIUM. The wired mux test exists and scans
gathered labels, but it still does not drive the partner-key metric through a
real successful partner request and manually emits rollup metrics.

H. End-of-impl AC sweep: PASS with LOW artifact drift. The convergence file
lists AC-1 through AC-22 with owner step and test path, but the closure
narrative is stale after round-2 fixes.

I. Test surface: FAIL MEDIUM. Default `go test ./...` passes, but new emitter
coverage remains partial for rollup tick completion and partner-key issue /
revoke events.

## Final verdict

READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 3 MEDIUM
