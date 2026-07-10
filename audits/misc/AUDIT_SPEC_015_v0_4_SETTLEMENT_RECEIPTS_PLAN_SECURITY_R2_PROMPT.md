# AUDIT_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PLAN_SECURITY_R2_PROMPT

You are re-auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
from the SECURITY lane.

Audit target: the build plan itself, not implementation code.

Controlling context:

- `specs/SPEC-022-verified-model-settlement.md` v0.1.4
- `specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`
- `specs/SPEC-015-receipts.md` v0.3.4

R1 security finding to verify closed:

- `SEC-M-1`: audit/storage redaction omitted receipt signatures and receipt
  public keys as explicitly prohibited audit material.

R2 focus:

- Confirm audit, telemetry, verdict rows, and operator surfaces cannot contain
  raw receipt signatures, raw receipt public keys, raw receipt envelopes, raw
  prompts, raw outputs, bearer tokens, receipt private keys, or provider-private
  state.
- Confirm raw receipt retention, if allowed, is segregated from audit/telemetry
  stores.
- Confirm receipt-key identity in settlement/audit records uses fingerprints or
  digests, not raw public keys.
- Re-check provider cheating, replay, late receipt, streaming partial-output,
  provider-only usage, unknown/future version, and premature SPEC-022
  enforce-mode activation risks.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`SEC-H-1`, etc.). Cite prompt text and SPEC/code
evidence.
