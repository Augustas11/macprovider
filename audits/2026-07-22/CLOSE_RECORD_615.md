# Closure record — Issue #615 (production exception register)

**Issue:** https://github.com/Augustas11/macprovider/issues/615  
**Closed:** 2026-07-22T08:52:34Z (PR [#681](https://github.com/Augustas11/macprovider/pull/681) merge)  
**As of:** 2026-07-22

---

## Closure summary

Issue #615 delivered the **mechanism** for production recovery exceptions to be
explicit, bounded, observable, expiring or fail-closed, and release-gated. Closure
does **not** mean every listed exception row is removed from Pearl — remaining
policy deltas are tracked in the register and owned by sibling issues.

---

## What closed it

| Lane | PR | Merged | Deliverable |
|------|-----|--------|-------------|
| Register schema + initial inventory | [#663](https://github.com/Augustas11/macprovider/pull/663) | 2026-07-21 | `ops/exceptions/production-exceptions.schema.json`, `production-exceptions.json`, runbook, OPS pointers |
| Enforcement scaffolding | [#681](https://github.com/Augustas11/macprovider/pull/681) | 2026-07-22 | `scripts/production_exceptions.py`, deploy/promote gates, anti-resurrection sync-check, tests |
| Pearl ops clearance (Entry 178) | [#684](https://github.com/Augustas11/macprovider/pull/684) | 2026-07-22 | `ops/runbooks/pearl-exception-clearance-20260722.md`; safe Pearl mutations; register open questions answered |
| Entry 172 evidence (register hygiene) | [#666](https://github.com/Augustas11/macprovider/pull/666), [#670](https://github.com/Augustas11/macprovider/pull/670) | 2026-07-21 | Referral activation evidence rows updated |

Decision log: **Entry 178** in [`beta/DECISION_CRITERIA.md`](../../beta/DECISION_CRITERIA.md).

---

## Pearl clearance outcomes (2026-07-22)

Evidence-bounded mutations on coordinator **v1.8.49** at `2026-07-22T10:45:27Z`:

**Cleared**

- Unexpected empty canary enable gates removed; DISABLED sentinel installed
- Six already-expired `provider_auth_policy.signature_exempt_until` rows NULLed
- `exc-cli-identity-signature-exemption` → **expired** (not yet **removed**)

**Intentionally still active** (register rows remain; removal owned elsewhere)

| Register ID | Live posture | Owning issue |
|-------------|--------------|--------------|
| `exc-onboarding-autotune-hello-gate` | `require_autotune_hello_gate: false` | [#582](https://github.com/Augustas11/macprovider/issues/582) |
| `exc-tokenless-recovery` | `allow_tokenless_provisional_bootstrap: true` | [#582](https://github.com/Augustas11/macprovider/issues/582) / [#585](https://github.com/Augustas11/macprovider/issues/585) |
| `exc-tier2-hash-mismatch-containment` | `require_hash_verified: false` | [#609](https://github.com/Augustas11/macprovider/issues/609) |
| `exc-canary-disabled-enable-gate` | Canary disabled; sentinel installed | [#584](https://github.com/Augustas11/macprovider/issues/584) |
| `exc-catalog-compatibility-bridges` | Dual autotune + Tier-2 catalog files | [#608](https://github.com/Augustas11/macprovider/issues/608) |
| `exc-v1840-coordinator-admission-bridge` | Legacy bridge fields absent; `/poolz` legacy count outstanding | [#615](https://github.com/Augustas11/macprovider/issues/615) follow-on / operator health |
| `exc-entry172-air-referral-activation` | Expired; referral overlay flag roll-off open | Entry 172 runbook |

Full inventory: [`ops/runbooks/pearl-exception-clearance-20260722.md`](../../ops/runbooks/pearl-exception-clearance-20260722.md).

---

## Residual work (sibling issues — not #615)

Physical exception-free proof and enforcement flips stay on these tracks:

- **[#608](https://github.com/Augustas11/macprovider/issues/608)** — single-authority catalog cutover; retire dual-file bridges (Partial [#688](https://github.com/Augustas11/macprovider/pull/688) landed)
- **[#609](https://github.com/Augustas11/macprovider/issues/609)** — Tier-2 hash algorithm fail-closed promote + physical `macprovider.snapshot-manifest.v1` buyer-serving proof before `require_hash_verified: true`
- **[#584](https://github.com/Augustas11/macprovider/issues/584)** — canary re-enable evidence and lifecycle
- **[#582](https://github.com/Augustas11/macprovider/issues/582)** — stranger/fresh onboarding without hello-gate bypass
- **[#585](https://github.com/Augustas11/macprovider/issues/585) / [#613](https://github.com/Augustas11/macprovider/issues/613)** — both Macs operate without temporary auth/catalog/onboarding exemptions

The register and promote gates continue to block stable promotion while active
rows with `blocks_stable_promotion: true` remain.

---

## Operator verification

```bash
python3 scripts/check-production-exceptions.py validate
python3 scripts/check-production-exceptions.py report
make check-exceptions
```

Promote gate (fail-closed on registered rows):

```bash
bash scripts/gate-production-exceptions-promote.sh
```

---

## References

- Runbook: [`ops/runbooks/production-exception-register.md`](../../ops/runbooks/production-exception-register.md)
- Register: [`ops/exceptions/production-exceptions.json`](../../ops/exceptions/production-exceptions.json)
- Pearl clearance: [`ops/runbooks/pearl-exception-clearance-20260722.md`](../../ops/runbooks/pearl-exception-clearance-20260722.md)
