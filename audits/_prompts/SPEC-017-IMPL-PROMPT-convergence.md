# SPEC-017 IMPL prompt — 3-lane codex audit convergence summary

**Convergence date:** 2026-06-26
**Final IMPL prompt version:** v6 (committed at `84dd586`)
**Verdict:** READY TO KICK OFF IMPLEMENTATION on all three lanes.

## Per-lane lock targets

All three lanes converged at `0 CRITICAL + 0 HIGH + 0 MEDIUM`.

| Lane | Rounds | Final lock round | Final result |
|---|---|---|---|
| ARCH | 5 | r5 (2026-06-26T04:06:01Z) | 0/0/0/0 + 4 INFO |
| CODE | 6 | r6 (2026-06-26T04:13:00Z) | 0/0/0/0 |
| SECURITY | 3 | r3 (2026-06-26T03:44:57Z) | 0/0/0/0 + 4 INFO |

## Per-lane trajectory

| Lane / Round | CRITICAL | HIGH | MEDIUM | LOW | Verdict |
|---|---|---|---|---|---|
| ARCH r1 | 1 | 5 | 3 | 1 | READY WITH FIX PASS |
| ARCH r2 | 1 | 3 | 2 | 1 | READY WITH FIX PASS |
| ARCH r3 | 1 | 2 | 0 | 0 | READY WITH FIX PASS |
| ARCH r4 | 1 | 0 | 0 | 1 | READY WITH FIX PASS |
| **ARCH r5** | **0** | **0** | **0** | **0** | **READY TO LOCK** |
| CODE r1 | 2 | 10 | 5 | 1 | NOT READY |
| CODE r2 | 1 | 4 | 2 | 0 | NOT READY |
| CODE r3 | 0 | 4 | 1 | 1 | NOT READY |
| CODE r4 | 1 | 2 | 1 | 1 | NOT READY |
| CODE r5 | 1 | 0 | 0 | 0 | NOT READY |
| **CODE r6** | **0** | **0** | **0** | **0** | **READY** |
| SECURITY r1 | 1 | 6 | 5 | 1 | READY WITH FIX PASS |
| SECURITY r2 | 0 | 1 | 0 | 2 | READY WITH FIX PASS |
| **SECURITY r3** | **0** | **0** | **0** | **0** | **READY TO KICK OFF** |

## Distinct CRITICAL findings absorbed across the loop

1. **Operator CLI fallback for `bucketed → exact`** (r1 ARCH C1 + r1 SECURITY C1). Removed; operator can only suppress `exact → bucketed` per §6.6.3.
2. **`stats_components_health.status` is a nonexistent column** (r1 CODE C1). Rewritten to use the SPEC's `generated_at` derivation at the handler.
3. **`partner_keys.created_by` NOT NULL omitted from CLI** (r1 CODE C2). Added with sensible default.
4. **Postgres role/DSN deploy gate missing + no fail-closed startup** (r2 ARCH C1). Added as production deploy gate; coordinator refuses to start when `stats.enabled=true` and any DSN is missing.
5. **`partner_keys_writer` cannot UPDATE WHERE id under the locked grant** (r2 CODE C1, then r3 ARCH C1 reversed). Resolved by making the role default-OFF for v0.1 and skipping `last_used_at` updates entirely; future SPEC v0.2 candidate can add the executable grant pattern.
6. **Step 4.B silently picks AC-8 over §5.6 burst** (r4 ARCH C1 + r4 CODE C1). Resolved by BLOCKING production nginx rate-limit config on a SPEC v0.1.7 reconciliation; non-production test harness allowed for AC-8 CI only.
7. **AC-10 SQL fixture invalid PostgreSQL** (r5 CODE C1). Rewritten with explicit `ON CONFLICT (provider_id)` target, pre-seed step, distinct rollback provider.

## Cross-lane convergence patterns

- **Same finding in multiple lanes:** the operator-CLI-fallback issue was caught independently by ARCH and SECURITY r1 — a confidence signal. The nginx burst conflict was caught by ARCH and CODE r4 — also independent confirmation.
- **Lane conflict resolved by SPEC fidelity:** r3 ARCH C1 contradicted r2 CODE C1's grant-widening fix. ARCH won because SPEC §7.2.4 is locked and the IMPL prompt cannot override a locked SPEC grant. Resolution: skip the role, document the limitation, defer to SPEC v0.2.

## Files produced

Audit prompts (one per lane):

- `specs/AUDIT_SPEC_017_IMPL_PROMPT_ARCH_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_PROMPT_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_PROMPT_SECURITY_PROMPT.md`

Per-round audit files (per the [[feedback-spec-audit-file-convention]] one-file-per-round rule):

- ARCH: `specs/SPEC-017-IMPL-PROMPT-arch-r{1..5}-audit.md`
- CODE: `specs/SPEC-017-IMPL-PROMPT-code-r{1..6}-audit.md`
- SECURITY: `specs/SPEC-017-IMPL-PROMPT-security-r{1..3}-audit.md`

This convergence file: `specs/SPEC-017-IMPL-PROMPT-convergence.md`.

## Implementation kickoff is unblocked

`BUILD_SPEC_017_IMPL_PROMPT.md` at v6 (commit `84dd586`) is the locked kickoff prompt. A fresh implementation session can paste it and begin Step 1 (schema + DB roles + grant inventory) without further IMPL-prompt audit rounds.

Known operator-action item before Step 4.B: file SPEC v0.1.7 candidate to reconcile §5.6 (burst 120) vs AC-8 (61st request returns 429) OR record an explicit production divergence in the cutover runbook. This is flagged in §1 prereqs of the IMPL prompt itself and does NOT block Steps 1-3 or Step 4.A/4.C.
