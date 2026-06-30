# AUDIT_BUILD_SPEC_015_v0_4_IMPL_CODE_PROMPT

You are auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the CODE lane before implementation begins.

Required reading:

1. `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2, especially §N and AC-43 through AC-71.
3. `specs/SPEC-015-v0-4-audit.md`.
4. Current repo file layout for the files named by the BUILD prompt.

Audit for implementability:

- step ordering and dependency correctness;
- real file/module references;
- missing acceptance-test coverage;
- contradictions with SPEC-015 v0.4.2;
- contradictions with locked v0.1/v0.2/v0.3 behavior;
- accidental SPEC-022 money-movement work inside this prerequisite prompt;
- streaming/non-streaming parity, zero-based `attempt_n`, strict
  `settlement_output_v1`, route snapshot, usage, timestamp, receipt-key, and
  redaction requirements.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
file paths and concrete lines.
