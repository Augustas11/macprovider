# AUDIT_BUILD_SPEC_015_v0_4_IMPL_ARCHITECT_R2_PROMPT

You are re-auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
from the ARCHITECT lane before implementation begins.

R1 ARCHITECT findings to verify closed:

- `ARCH-H-1`: coordinator receipt verdict state depended on verifier behavior
  that did not land until a later step.
- `ARCH-H-2`: shared Go canonicalization was not architected early enough for
  coordinator/gateway use, and module boundaries prevented importing
  `phase7-verify/internal/*`.
- `ARCH-M-1`: the prompt referenced non-existent
  `phase4-coordinator/internal/buyer/forward_loop.go`.

Also verify the revised step sequence preserves module boundaries between
provider, coordinator, gateway, and verifier, and keeps SPEC-022 enforce-mode
settlement as a downstream implementation.

Do not re-audit clean security/product/adversarial concerns except where the R2
architecture edits create a direct architecture contradiction.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ARCH-C-1`, `ARCH-H-1`, `ARCH-M-1`, etc.). Cite file
paths and concrete lines.
