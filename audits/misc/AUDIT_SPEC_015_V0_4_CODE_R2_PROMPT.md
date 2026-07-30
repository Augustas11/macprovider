# AUDIT_SPEC_015_V0_4_CODE_R2_PROMPT

You are re-auditing `specs/SPEC-015-receipts.md` from the CODE lane.

Audit target: v0.4.1-draft deltas only, centered on §N
"Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as fixed
unless a v0.4 clause contradicts it.

R1 CODE findings to verify closed:

- `CODE-H-1`: `usage` was not strict enough to implement as a signed tuple
  field.
- `CODE-H-2`: route snapshot digest was not concretely defined and omitted
  SPEC-022-required snapshot fields.
- `CODE-H-3`: streaming `output_hash` canonicalization was not implementable
  enough.
- `CODE-H-4`: chargeability rows were not deterministic.
- `CODE-H-5`: receipt-key binding allowed incompatible implementations.
- `CODE-M-1`: timestamp policy was too abstract for runnable tests.
- `CODE-M-2`: acceptance criteria were not runnable enough for BUILD IMPL.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
SPEC text and concrete repo/spec evidence.
