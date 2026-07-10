# AUDIT_BUILD_SPEC_015_v0_4_IMPL_ARCHITECT_PROMPT

You are auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the ARCHITECT lane before implementation begins.

Required reading:

1. `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2.
3. `specs/SPEC-022-verified-model-settlement.md`.
4. Current repo layout for the modules named by the BUILD prompt.

Audit for architecture and rollout coherence:

- correct module boundaries between provider, coordinator, gateway, and
  verifier;
- step sequencing and PR grouping;
- whether shared canonicalization/fixture work is placed early enough;
- whether coordinator-internal verification and phase7 verifier expectations
  are realistic;
- whether the prompt preserves SPEC-022 as a downstream consumer instead of
  mixing in enforce-mode settlement;
- whether streaming, failover, retention, and diagnostics are integrated
  without circular dependencies.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ARCH-C-1`, `ARCH-H-1`, `ARCH-M-1`, etc.). Cite file
paths and concrete lines.
