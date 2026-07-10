# AUDIT_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PLAN_ADVERSARIAL_R2_PROMPT

You are re-auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
as an ADVERSARIAL VERIFICATION critic.

Audit target: the build plan itself, not implementation code.

Controlling context:

- `specs/SPEC-022-verified-model-settlement.md` v0.1.4
- `specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`
- `specs/SPEC-015-receipts.md` v0.3.4

R1 adversarial findings to verify closed:

- three-way SPEC-022 R-3.3 model-hash equality check;
- R-5.6 partial-output binding unavailable -> pending until deadline, then
  quarantine with no buyer final debit and no provider credit;
- R-4.5 strict timestamp policy, not clock-skew warnings only;
- explicit mapping from receipt verifier results into SPEC-022 `pending`,
  `verified`, `quarantined`, and `zero_settled` outcomes;
- monotonic route-attempt identity requirement;
- security R1 receipt signature/public-key redaction coverage.

Try to break the plan. Assume a provider wants to get paid while serving the
wrong model, replaying a receipt, forging streaming partials, exploiting
failover overlap, exploiting timestamp skew, using an inconclusive verifier
result, or getting SPEC-022 enforce mode wired before receipts are
settlement-capable.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ADV-H-1`, etc.). Cite prompt text and SPEC evidence.
