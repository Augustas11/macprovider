# AUDIT_BUILD_SPEC_015_v0_4_IMPL_SECURITY_PROMPT

You are auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the SECURITY lane before implementation begins.

Required reading:

1. `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2, especially §N.1 through §N.10.
3. `specs/SPEC-015-v0-4-audit.md`.
4. `CLAUDE.md` sensitive-path and PR rules.

Audit for security gaps:

- false-positive settlement paths;
- replay, wrong-account, wrong-attempt, wrong-key, wrong-snapshot, and
  wrong-terminal-state handling;
- provider timestamp influence over deadline/quarantine;
- raw receipt/signature/pubkey/prompt/output/token leakage;
- streaming partial-output double charge or double credit;
- provider-only usage becoming money authority;
- overclaiming the model verification trust boundary;
- accidental SPEC-022 enforce-mode money movement before receipt prerequisite
  closure.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`SEC-C-1`, `SEC-H-1`, `SEC-M-1`, etc.). Cite file
paths and concrete lines.
