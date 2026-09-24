# #1693 implementation audit — findings record

Three-lane codex audit (code / security / architecture) over the full
`origin/main...HEAD` diff of branch `feat/1693-pricing-content-lane`. Prompts:
`AUDIT_1693_IMPL_<lane>_PROMPT.md` (round 1), `_R2_PROMPT.md`, `_R3_PROMPT.md`.
Round 3 was the final audit round by operator decision; further bug-finding is by
the e2e plan (`docs/testing/1693-pricing-lane-e2e-plan.md`).

| Round | HEAD | code | security | architecture |
|---|---|---|---|---|
| 1 | f0c438f5 | REJECT 0C/1H/1M/0L | REJECT 0C/1H/3M/0L | REJECT 0C/1H/2M/1L |
| 2 | a4889920 | REJECT 0C/1H/1M/0L | APPROVE-WITH-CHANGES 0C/0H/1M/2L | REJECT 0C/1H/1M/1L |
| 3 | b3db492d | **APPROVE 0/0/0/0** | **APPROVE 0/0/0/0** | **APPROVE 0/0/0/0** |

## Round 1 → fixed in a4889920 (+ 1582e33a, d00ab9e3 docs)

- HIGH (all lanes): wholesale picked the exact identity instead of failing closed
  on conflicting generations → independent resolution, null = absent, conflict
  fails closed (`ErrWholesaleConflictingGenerations`).
- MEDIUM SEC-M1: acknowledged digest did not cover Go-resolved model prices →
  acknowledged object includes `model_resolutions`.
- MEDIUM SEC-M2: recovery helper trusted lock files → fstat validation, unsafe
  lock fails closed.
- MEDIUM CODE-2: failure to mark `verified` reported success; verified journal
  could be downgraded → separate steps, monotonic terminal phases.
- MEDIUM ARCH-002: runbook anchor missing → §Pricing txn.
- MEDIUM ARCH-003: enabling rollout could not pass preflight → §Enabling rollout
  (updater bundle is a prerequisite); release train updated on `main`.
- LOW ARCH-004: CONFORMANCE described landed code as future → updated.

## Round 2 → fixed in b3db492d

- HIGH CODE-R2-1 / MEDIUM SEC-M4 / MEDIUM ARCH-002: deploy-and-pricing conflict
  hand procedure deadlocked and could restart a mixed pair → tested
  `coordinator-pricing-recover --resolve-deploy-conflict`.
- HIGH ARCH-001: downgrade to a pre-#1693 runtime re-prices wholesale history →
  runtime-floor marker enforced by deploy, deploy recovery and the updater;
  SPEC-023-R018 rule 12; operator rule for old tags.
- MEDIUM CODE-R2-2: recovery mutated before full compare-and-swap → whole-tuple
  preflight.
- LOW SEC-L1 (Unicode format/bidi escaping), SEC-L2 (runbook wholesale wording),
  ARCH-003 (R017 rationale) → fixed.

## Carried (not fixed in this PR)

- **SEC-M3, MEDIUM, PRE-EXISTING.** `deploy-pearl-vps.sh` (preserve-live mode)
  copies the raw live `coordinator.yaml` to the operator machine for local
  validation and drift checks. This diff does not change those lines. Follow-up:
  do normalization, secret removal and comparison on the host and transfer only a
  secret-free projection or digest.
- **Operator-rule gap (documented, R018 rule 12).** A deploy script from a tag
  older than #1693 cannot enforce the runtime floor; running one after
  enablement is prohibited by the runbook. E2 scenario V10 tests the documented
  marker check.

## Open for testing (from the plan, not audit findings)

Everything in the e2e plan's E1/E2 tiers; live evidence (E3) gates CONFORMANCE
promotion of SPEC-005-R013 and SPEC-023-R018.
