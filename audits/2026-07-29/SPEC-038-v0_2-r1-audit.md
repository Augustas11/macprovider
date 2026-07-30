# SPEC-038 v0.2 r1 audit convergence

Date: 2026-07-29
Branch: `spec/038-v0.2-reframe`
Base: `origin/main`
Scope:

- `specs/SPEC-038-continuous-batching.md`
- `specs/CONFORMANCE.json`
- `specs/README.md`
- `audits/2026-07-29/SPEC_038_V0_2_*_AUDIT_PROMPT.md`

## Summary

SPEC-038 v0.2 rewrites the superseded v0.1 continuous-batching contract into
a locally owned scheduler/serving spec that consumes a forward-referenced
SPEC-039 paged engine. The audit loop converged at 0 CRITICAL, 0 HIGH, and 0
MEDIUM findings across code, security, and architect lanes.

## Lane results

| Lane | C | H | M | L | INFO | Verdict |
|---|---:|---:|---:|---:|---:|---|
| Code r1 | 0 | 0 | 1 | 2 | 0 | REQUEST CHANGES |
| Code focused re-audit | 0 | 0 | 0 | 0 | 0 | PASS |
| Security | 0 | 0 | 0 | 0 | 1 | PASS |
| Architect | 0 | 0 | 0 | 1 | 0 | PASS |

## Fixed findings

1. **MEDIUM - AC-19 cache-billing parity underspecified.**
   Fixed by restoring explicit expected outcomes for sticky-hit discounts,
   ambiguous/full-rate settlement, retry/no duplicate receipt, invalid-range
   quarantine, and cross-key isolation.
2. **LOW - stale SPEC-023 version in dependency prose.**
   Fixed by referencing SPEC-023 without hardcoding a version.
3. **LOW - audit-history path pointed at `specs/`.**
   Fixed by pointing audit records to `audits/2026-07-29/`.

## Carried findings

- **INFO - SPEC-039 forward dependency is prose-only until SPEC-039 exists.**
  This is intentional because the current governance validator rejects
  structured `depends_on` references to absent canonical spec records. SPEC-038
  states the forward-reference boundary in prose and keeps activation
  fail-closed until the local scheduler-plus-SPEC-039 capability exists.

## Validation evidence

Passed locally after fixes:

- `python3 scripts/gen_spec_index.py --check`
- `python3 scripts/gen_spec_index.py --lint`
- `python3 scripts/check_spec_governance.py --base-ref origin/main`
- `python3 -m unittest scripts.tests.test_spec_governance scripts.tests.test_spec_pr_declaration`
- `git diff --check origin/main -- specs/SPEC-038-continuous-batching.md specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC_038_V0_2_CODE_AUDIT_PROMPT.md audits/2026-07-29/SPEC_038_V0_2_SECURITY_AUDIT_PROMPT.md audits/2026-07-29/SPEC_038_V0_2_ARCHITECT_AUDIT_PROMPT.md`

Final verdict: PASS - 0 CRITICAL, 0 HIGH, 0 MEDIUM.
