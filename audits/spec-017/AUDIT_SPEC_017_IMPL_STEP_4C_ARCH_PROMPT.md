# AUDIT_SPEC_017_IMPL_STEP_4C — Architecture lane

Operator-paste prompt to audit the **Step 4.C IMPL diff**
(observability, runbook, changelog, end-of-impl AC sweep) under
PR `Augustas11/macprovider#173` from the architecture lens.

Audit target is the **Step 4.C implementation diff** layered on
top of Step 4.B. SPEC-017 v0.1.8 is LOCKED;
`BUILD_SPEC_017_IMPL_PROMPT.md` is the controlling kickoff.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_4C-arch-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.C IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the ARCHITECTURE lens.

Step 4.C scope:
- Structured-log event emissions: `stats_request_served`,
  `stats_rollup_tick_completed`, `stats_rollup_drift_detected`,
  `stats_handler_panic`, `stats_partner_key_issued`,
  `stats_partner_key_revoked`.
- Prometheus metrics: `stats_request_total{endpoint,status,tier}`,
  `stats_partner_key_request_total{partner_key_id}`,
  `stats_rollup_lag_seconds{component}`,
  `stats_rollup_errors_total{component}`,
  `stats_rate_limit_exceeded_total{tier,endpoint}`.
- OPS.md runbook entries: rotate / revoke / panic-restart /
  emergency visibility revert / SPEC-014 v0.9 disclosure
  obligation + sign-off template.
- docs/network-stats-api/CHANGELOG.md v0.1.8 entry.
- AC-20 CI assertion + metric-label hygiene test.
- End-of-implementation 22-AC final sweep against the merged
  main; convergence record at
  `specs/SPEC-017-IMPL-STEP_4C-r{M}-convergence.md` quoting the
  §6.6.2 sign-off template and noting whether production
  SPEC-014 v0.9 disclosure is satisfied.

Output: specs/SPEC-017-IMPL-STEP_4C-arch-rM-audit.md.

Severity model:
- CRITICAL — a locked SPEC §6.6.2 / §8.5 / §9.4 invariant is
  violated: Prometheus metric label carries raw token,
  `token_hash`, prefix-only-but-secret-derived value, untrusted
  Origin string, partner_key.label, or Authorization fragment;
  AC-20 CI assertion missing or trivially passable; OPS.md
  partner-key recipe shows a real-looking `mpk_*` string;
  structured-log emission includes the raw token or 43-char
  body; Step 4.C PR convergence file misses the §6.6.2 sign-off
  template entirely (per BUILD §2 v11 ARCH r10 H1, the template
  MUST be in OPS.md verbatim).
- HIGH — observability surface drift from SPEC §8.5: missing
  one of the six required structured events; partner-key
  request metric uses high-cardinality label outside
  `partner_keys.id` (label_text, prefix, or arbitrary string);
  rollup drift event omits one of the §9.4 axis fields
  (axis, divergence_pct, rebuild_value, incremental_value);
  changelog entry missing PR numbers per step.
- MEDIUM — structural ambiguity, runbook step missing one of
  the four locked entries (rotate / revoke / restart /
  visibility revert), sign-off template present but missing
  the "SPEC-014 v0.9 NOT YET" cutover-prerequisite annotation.
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (before writing findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections
  6.6.2 (partner exact-$ disclosure obligation),
  8.5 (changelog format), 9.4 (drift event), 9.6 (rollup
  errors), the §9.5 health budgets (Step 4.C metrics SHOULD
  surface health.status timeseries-side).
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 2 Step 4.C
  (entire "4.C Observability, runbooks, changelog" block,
  including the v0.1.7-tightened §6.6.2 cutover gate paragraph
  and v11 ARCH r10 H1 sign-off-template paragraph) plus the
  AC matrix for AC-15/AC-20 step ownership.
- Step 3 + Step 4.A + Step 4.B convergence records.
- All ARCH r1..r(M-1) audit files for Step 4.C.
- Step 4.C implementation diff: `git diff <Step 4.B tip>..HEAD
  -- phase4-coordinator/ OPS.md docs/`.

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Structured-log events** — all six emitters wired through
   the existing zerolog instance (the same redaction-context
   middleware Step 3 already attaches). Events appear in the
   coordinator logs under a stable key (`event=stats_*`) AND
   carry only the locked field set per BUILD §2 Step 4.C
   bullet list.

B. **Prometheus metric inventory + label hygiene** — five
   metrics declared, no extras. Labels follow the §SECURITY
   M5 hygiene rule: `partner_key_id` INTEGER only, NEVER
   prefix/label-text/token-derived/Origin-derived. `tier`
   limited to `"public"` / `"partner"`. `endpoint` limited to
   `overview` / `leaderboard` / `health`.

C. **OPS.md runbook entries** — four locked entries present
   verbatim: rotate, revoke, restart-after-panic-loop,
   emergency visibility revert. The visibility revert entry
   MUST note that the CLI refuses `mode=exact` (cross-
   reference to Step 4.A boundary).

D. **§6.6.2 disclosure obligation** — disclosure copy added
   to OPS.md under "Partner-key exact-dollar exposure —
   provider disclosure obligation". The verbatim sign-off
   template lives in OPS.md. The Step 4.C convergence file
   MUST quote it AND explicitly state whether SPEC-014 v0.9
   live deployment is satisfied (per BUILD §2 v11 ARCH r10 H1).

E. **CHANGELOG.md v0.1.8 entry** — per §8.5 format: version
   header, PR-by-step references, SPEC version, locked-API
   delta summary.

F. **AC-20 CI assertion** — runs on every PR; the SQL
   assertion `SELECT COUNT(*) FROM provider_visibility_audit
   WHERE new_mode='exact' AND actor_kind='operator'` returns 0.
   Wired into the existing integration job or a dedicated CI
   step.

G. **Metric-label hygiene test** — emits all five metrics
   under test load, scans every label value for raw token,
   token_hash, prefix, Authorization-fragment, Origin-fragment.
   Counts MUST be 0.

H. **End-of-impl 22-AC sweep** — a final convergence file
   re-runs all 22 ACs (v0.1.8 added AC-22 auth-failure tier).
   Each AC row records: owner step, test path, last green run.

I. **Cross-step bleed** — Step 4.C MUST NOT modify Step 3
   handler semantics or Step 4.A CLI surface. Any change to
   those surfaces is a HIGH (it should have run through that
   step's audit lanes).

Validation steps (run before writing findings):
- `git diff --name-only <4.B tip>..HEAD -- phase4-coordinator/
  OPS.md docs/ specs/` to scope.
- `rg -n "stats_partner_key_issued|stats_partner_key_revoked|
   stats_rollup_drift_detected|stats_handler_panic|
   stats_request_served|stats_rollup_tick_completed"
   phase4-coordinator/`.
- `rg -n "stats_request_total|stats_partner_key_request_total|
   stats_rollup_lag_seconds|stats_rollup_errors_total|
   stats_rate_limit_exceeded_total" phase4-coordinator/`.
- Scan OPS.md for the four runbook entries + the disclosure
  section + the sign-off template.
- `cat docs/network-stats-api/CHANGELOG.md`.

Output structure (one document per round, fresh file). Same
shape as Step 4.A ARCH lane.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
