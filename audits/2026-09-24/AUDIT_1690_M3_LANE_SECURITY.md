Read `audits/2026-09-24/AUDIT_1690_M3_SPEC_COMMON.md` first.

**Lane: trust and money-path security.** As written, can the amended SPECs let paid routing, or `pool_operator_attested` usage, reach:
- global traffic,
- non-members, delegated providers, or a different pool,
- a runtime not on the allowlist,
- a stale or disputed manifest,
- or an old CLI?

Also check:
- whether any trust decision rests on provider-asserted data (the hello `runtime_source`, CLI-reported usage) rather than on coordinator-recorded state;
- the `policy-core/v2` signing and domain separation, v1/v2 downgrade and rollback, the reserved `extensions` field handling, and the "non-empty allowlist requires enforce" rule;
- the per-request `pool_runtime_authorization` in SPEC-015 R006: can it be replayed, reused across requests or providers, or forged?

Evaluate by reading only (see the method constraint).
