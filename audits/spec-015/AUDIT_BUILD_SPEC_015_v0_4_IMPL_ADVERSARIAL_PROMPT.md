# AUDIT_BUILD_SPEC_015_v0_4_IMPL_ADVERSARIAL_PROMPT

You are auditing `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
as an adversarial verification reviewer before implementation begins.

Required reading:

1. `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2.
3. `specs/SPEC-015-v0-4-audit.md`.

Try to break the implementation plan. Look for ways a malicious or faulty
provider, gateway, coordinator, retry path, or operator setting could cause:

- positive provider settlement without a signed catalog-matching receipt;
- buyer final debit without the exact route-time receipt binding;
- duplicate/overlapping streaming prefix double charge;
- late receipt resurrection;
- provider usage or timestamp becoming authority;
- receipt replay across account/request/attempt/provider/key/snapshot;
- trust-boundary overclaim.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ADV-C-1`, `ADV-H-1`, `ADV-M-1`, etc.). Cite file
paths and concrete lines.
