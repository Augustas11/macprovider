# AUDIT_SPEC_015_V0_4_ADVERSARIAL_PROMPT

You are auditing `specs/SPEC-015-receipts.md` as an ADVERSARIAL VERIFICATION
critic.

Audit target: v0.4 deltas only, centered on the new `0.4.0-draft` header
and §N "Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as
fixed unless a v0.4 clause contradicts it.

Controlling context:

- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- SPEC-022 v0.1.4 requirements quoted or referenced by §N

Lock bar: 0 critical, 0 high, 0 medium.

Try to break the design. Assume a provider wants to get paid while serving the
wrong model, replaying a receipt, forging streaming partials, abusing failover
overlap, exploiting timestamp skew, exploiting unknown receipt versions,
reusing a key from another route snapshot, or pushing SPEC-022 enforce mode
before receipts are settlement-capable.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ADV-C-1`, `ADV-H-1`, `ADV-M-1`, etc.). Cite SPEC
text and concrete repo/spec evidence.
