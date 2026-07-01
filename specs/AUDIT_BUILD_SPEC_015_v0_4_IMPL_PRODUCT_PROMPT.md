# AUDIT_BUILD_SPEC_015_v0_4_IMPL_PRODUCT_PROMPT

You are auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
as a product design critic before implementation begins.

Required reading:

1. `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2, especially §N.10 and AC-67/AC-68.
3. `specs/SPEC-015-v0-4-audit.md`.

Audit for product and operator usability gaps:

- whether buyers can understand what the receipt verifies and does not verify;
- whether providers get actionable rejection/deadline diagnostics;
- whether streaming behavior remains compatible with agentic tooling and
  stock OpenAI-compatible clients;
- whether operator diagnostics are useful without leaking raw sensitive
  material;
- whether the prompt accidentally frames this as beta-only rather than the
  first full-product receipt trust floor;
- whether acceptance evidence is clear enough for a launch decision.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`PD-C-1`, `PD-H-1`, `PD-M-1`, etc.). Cite file paths
and concrete lines.
