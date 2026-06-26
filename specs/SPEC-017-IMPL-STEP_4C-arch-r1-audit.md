# SPEC-017 IMPL Step 4.C Architecture Audit r1

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `2130a87` (`impl(017): Step 4.C - structured events + Prometheus metrics + OPS.md + CHANGELOG`)
Diff base checked: `022cd55` (Step 4.B tip)
Lens: ARCHITECTURE
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C

## Verdict

REQUEST CHANGES.

Blocking count: 1 CRITICAL / 3 HIGH / 1 MEDIUM / 1 LOW / 9 INFO.

Lock target is not met. The largest blocker is not the OPS.md template itself
(it is present); it is that the Step 4.C convergence artifact is absent, so the
PR has no final 22-AC sweep and no convergence-side quote/status statement for
the Section 6.6.2 production partner-key issuance gate.

## Required Reading And Validation

Required reading completed:

- `CLAUDE.md`.
- `specs/SPEC-017-network-stats-api.md` v0.1.8 focused on Sections 6.6.2,
  8.5, 9.4, 9.5, 9.6, and AC-15/AC-20/AC-22.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C, the v0.1.7-tightened
  Section 6.6.2 cutover gate, the v11 ARCH r10 H1 convergence/template rule,
  and the AC-15/AC-20 ownership matrix.
- `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
- Step 4.A and Step 4.B prior architecture audit files present in this
  worktree: Step 4.A arch r1-r2 and Step 4.B arch r1-r3.
- No prior Step 4.C architecture audit files were present.

Commands run:

- `git fetch origin` - completed; local branch tracks
  `origin/impl/spec-017-step-1`.
- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - scoped Step 4.C diff reviewed.
- Required event sweep:
  `rg -n "stats_partner_key_issued|stats_partner_key_revoked|stats_rollup_drift_detected|stats_handler_panic|stats_request_served|stats_rollup_tick_completed" phase4-coordinator/`.
- Required metric sweep:
  `rg -n "stats_request_total|stats_partner_key_request_total|stats_rollup_lag_seconds|stats_rollup_errors_total|stats_rate_limit_exceeded_total" phase4-coordinator/`.
- OPS.md scan for the four runbook entries, disclosure section, and sign-off
  template.
- `cat docs/network-stats-api/CHANGELOG.md`.
- `go test ./internal/stats/metrics ./internal/stats/...` from
  `phase4-coordinator` - PASS.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - FAIL: `specs/SPEC-017-IMPL-STEP_4B-security-r4-audit.md:169: new blank line at EOF`.

## Findings

### CRITICAL

1. Missing Step 4.C convergence file means the Section 6.6.2 sign-off template
   is not quoted in convergence, and the required final 22-AC sweep is absent.

   Evidence:
   - `find specs -maxdepth 1 -name 'SPEC-017-IMPL-STEP_4C*' ...` returned no
     Step 4.C convergence file and no prior Step 4.C arch audit file.
   - The Step 4.C diff adds no
     `specs/SPEC-017-IMPL-STEP_4C-r{M}-convergence.md`.
   - `OPS.md:725-736` contains a sign-off template, and `OPS.md:738-742`
     states SPEC-014 v0.9 is not yet satisfied, but the BUILD v11 ARCH r10 H1
     rule requires the convergence file to quote the template and explicitly
     state whether the live production sign-off is satisfied.

   Risk: The PR can appear converged without the locked end-of-implementation
   proof: all 22 ACs re-run, template quoted, and production SPEC-014 v0.9
   disclosure status recorded as a cutover prerequisite.

   Fix: Add a fresh Step 4.C convergence file after the audit loop closes. It
   must include the verbatim OPS.md sign-off template, explicitly state
   `SPEC-014 v0.9 commit SHA + deploy dates = NOT YET` unless live deployment
   is actually complete, and include the 22-AC final sweep with owner step,
   test path, and last green run for every AC.

### HIGH

1. `stats_handler_panic` does not use the locked panic-event field set and emits
   an additional stack-bearing `event=stats_handler_panic_stack`.

   Evidence:
   - BUILD Step 4.C requires `stats_handler_panic` fields
     `(request_id, route)` and says no stack in public log.
   - `phase4-coordinator/internal/stats/middleware.go:109-114` emits
     `event=stats_handler_panic` with `path`, `method`, and `panic_type`; it
     does not emit `request_id` or `route`.
   - `phase4-coordinator/internal/stats/middleware.go:115-118` also emits
     `event=stats_handler_panic_stack` with `stack`.

   Risk: The panic event is not the contract partners/operators are told to
   query, and the extra `stats_*` stack event widens the observability surface
   beyond the six-event taxonomy. Even at debug level, a structured
   `event=stats_*` stack payload is not the locked Step 4.C public log shape.

   Fix: Emit only `event=stats_handler_panic` with the locked fields. If a
   private debug stack is retained, do not tag it as a `stats_*` event and keep
   it outside the public structured-event taxonomy.

2. `stats_partner_key_issued` includes a token-derived `prefix` and extra
   `created_at` field outside the locked Step 4.C field set.

   Evidence:
   - BUILD Step 4.C locks the event to `(partner_keys.id, label, created_by,
     rotated_from_id_or_null)` and says not the raw token.
   - `phase4-coordinator/cmd/coordinator/partnerkeys.go:293-300` emits
     `id`, `label`, `prefix`, `created_by`, `rotated_from_id`, and
     `created_at`.
   - `prefix` is derived from the raw token (`mpk_` plus the first token body
     characters), and Step 4.C's metric-label rule explicitly treats prefix as
     forbidden secret-derived material.

   Risk: The event becomes a durable log sink for token-derived material that
   the Step 4.C contract did not authorize. It also breaks the closed field-set
   guarantee for log consumers.

   Fix: Remove `prefix` and `created_at` from the structured event. Keep
   operator-facing CLI metadata separate from the locked `stats_*` event if
   needed, but do not put prefix into `event=stats_partner_key_issued`.

3. The public changelog cites PR #173 only once, not PR numbers per step as
   required by the Step 4.C changelog contract.

   Evidence:
   - `docs/network-stats-api/CHANGELOG.md:32-43` says the release was
     delivered in PR #173 across Step 1, Step 2, Step 3, Step 4.A, Step 4.B,
     and Step 4.C.
   - The per-step table has `Step`, `Scope`, and `Audit-loop rounds` columns,
     but no PR column or per-step PR reference.
   - The audit prompt severity model says a changelog entry missing PR numbers
     per step is HIGH.

   Risk: A reader cannot map each shipped surface to the PR reference required
   by SPEC Section 8.5 and the Step 4.C kickoff. This weakens release
   traceability exactly at the final public-changelog lock point.

   Fix: Add a PR reference column to the step table. If all steps truly landed
   in PR #173, list `#173` on every row rather than only in the paragraph.

### MEDIUM

1. The metric-label hygiene test is package-synthetic and omits the required
   Origin-fragment scan.

   Evidence:
   - `phase4-coordinator/internal/stats/metrics/metrics_test.go:37-53` drives
     metric vectors directly, not the handler/auth/rate-limit paths under a
     request containing a raw `mpk_*` token, Authorization header, and Origin.
   - `phase4-coordinator/internal/stats/metrics/metrics_test.go:34` denies
     `mpk_`, `token_hash`, and `Authorization`, but does not scan for an
     Origin fragment.
   - The Step 4.C prompt requires the hygiene test to emit all five metrics
     under test load and scan every label value for raw token, token_hash,
     prefix, Authorization-fragment, and Origin-fragment.

   Risk: The current unit test proves the metrics package can be used safely,
   but it does not prove the wired observability path never passes attacker
   request data into labels. That leaves the main architectural risk of the
   test partially unexercised.

   Fix: Keep the package unit test, and add a wired handler/rollup metrics test
   using a fresh registry. Send representative public, partner, invalid-bearer,
   rate-limited, and Origin-bearing requests; gather the registry; scan every
   label value for the raw token, 43-character body, prefix, `token_hash`,
   Authorization fragment, and Origin host/string.

### LOW

1. The scoped diff fails whitespace validation because a newly added Step 4.B
   audit artifact has a blank line at EOF.

   Evidence: `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
   reports `specs/SPEC-017-IMPL-STEP_4B-security-r4-audit.md:169: new blank line at EOF`.

   Risk: Non-functional, but this is part of the Step 4.C scoped diff and
   should be cleaned before lock.

   Fix: Remove the trailing blank line.

### INFO

- The required six event names are present somewhere in `phase4-coordinator/`.
- The five required metric names are declared in
  `phase4-coordinator/internal/stats/metrics/metrics.go:55-93`.
- Production uses a coordinator-owned Prometheus registry at
  `phase4-coordinator/cmd/coordinator/main.go:543-558`, so the `/metrics`
  handler is not implicitly polluted by Go/process default collectors.
- `stats_partner_key_request_total` is declared with only
  `partner_key_id`, and production increments it with
  `strconv.FormatInt(pkid, 10)` at
  `phase4-coordinator/internal/stats/middleware.go:195-197`.
- AC-20 is present in the existing unconditional PR CI path:
  `.github/workflows/ci.yml:167-187` runs `make test-coordinator-integration`,
  and `phase4-coordinator/internal/stats/integration_test.go:448-475`
  asserts zero rows for
  `new_mode = 'exact' AND actor_kind = 'operator'`.
- OPS.md contains the four requested runbook entries at `OPS.md:623-691`.
- OPS.md explicitly says the visibility CLI has no operator exact-enable path
  at `OPS.md:683-691`.
- OPS.md contains the partner-key exact-dollar exposure disclosure, blocking
  production issuance gate, sign-off template, and current NOT YET status at
  `OPS.md:693-742`.
- `go test ./internal/stats/metrics ./internal/stats/...` passed locally.

## Category Sweep

A. Structured-log events: FAIL. The event names exist, but the locked field-set
contract is not met for panic and partner-key issuance events. `stats_request_served`
also emits an extra `method` field at `middleware.go:177-184`, and
`stats_rollup_drift_detected` includes extra `window`, `provider_id_sample`,
`delta_ratio`, and `threshold` fields at `rollup/rebuild.go:231-242`. The
blocking architecture risk is captured in HIGH findings 1 and 2.

B. Prometheus metric inventory and label hygiene: PASS inventory, MEDIUM test
gap. The code declares the five required metrics and no additional custom
metrics in the stats registry. Production label values for `partner_key_id`,
`endpoint`, and `tier` are structurally bounded in the request path, but the
test does not exercise the wired request path or Origin-fragment scan.

C. OPS.md runbook entries: PASS. Rotate, revoke, panic-restart-loop recovery,
and emergency visibility revert entries are present. The visibility revert text
notes that operator exact-enable is refused and directs bucketed-to-exact to
SPEC-014 v0.9 provider-authenticated portal flow.

D. Section 6.6.2 disclosure obligation: PASS in OPS.md, CRITICAL gap in
convergence. OPS.md has the disclosure section, blocking gate, sign-off
template, and NOT YET annotation. The required convergence file does not exist.

E. CHANGELOG.md v0.1.8 entry: FAIL. The version header, SPEC version, and
locked API delta summary are present, but PR references are not recorded per
step.

F. AC-20 CI assertion: PASS. Existing Step 1 integration coverage is wired to
run on every PR and contains the required SQL assertion.

G. Metric-label hygiene test: FAIL WITH MEDIUM. The package-level hygiene test
exists and passes, but it does not meet the Step 4.C wired-test requirement.

H. End-of-implementation 22-AC sweep: FAIL. No Step 4.C convergence file exists,
so there is no owner/test-path/last-green row for each of the 22 ACs.

I. Cross-step bleed: PASS WITH OBSERVABILITY-SCOPE CAVEAT. Step 4.C modifies
handler middleware and partner-key CLI surfaces to emit observability data, as
the kickoff scope requires. I did not find a Step 3 handler semantic change or
Step 4.A CLI command-surface change outside that observability purpose. The
partner-key issuance event's `prefix` field is still a HIGH observability field
set violation, not a separate CLI command-semantics bleed finding.

## Final Recommendation

Do not lock Step 4.C yet. Close the convergence-file CRITICAL, remove the
structured-log field-set drift, fix the changelog per-step PR references, and
replace or supplement the metric-label hygiene test with a wired request-path
scan before the next architecture round.
