# #584 demand-floor go/no-go — 2026-08-07

**Verdict: NO-GO** — leave canary disabled; do not arm the demand floor.

## Decision

| Gate | Status |
|------|--------|
| Issue #584 redesign merged (hermetic FR-CAN22/23, budgets, correlation) | Pass (code closed 2026-07-23) |
| Production exception `exc-canary-disabled-enable-gate` | Still **active** |
| Physical per-tier baselines (`584-physical-baseline-matrix.md`) | **Missing** — no signed floor records on file |
| Emergency-disable drill evidence on Pearl | Not re-run for this window |
| Operator-signed go for timer / enable-gate / `pool.canary_enabled` | **Not granted** |

Until physical baselines + signed acceptance exist, Pearl stays:

- `/var/lib/macprovider-canary-buyer/DISABLED` present
- `/etc/macprovider-canary-buyer/enabled` absent
- `pool.canary_enabled: false`
- `canary-buyer.timer` disabled
- `PEARL_UPDATER_BUYER_CANARY_MODE=disabled` (updater apply path)

## Why this is still NO-GO after issue close

Closing #584 sealed the **redesign package**, not a production re-enable.
The exception register’s removal condition is explicit: reviewed physical
evidence + approval. Prebeta P5 (demand floor) remains gated on that same bar.

## Interim provider UX (already shipped)

- MALIBU emission ticks (counter motion without buyer demand)
- Adaptive USD + eligibility copy on Malibu earnings card
- Do **not** invent a second unapproved buyer probe

## Re-open criteria (next go/no-go)

1. Fill `ops/runbooks/584-physical-baseline-matrix.md` cells for fleet tiers present on Pearl
2. One operator-approved liveness-only day behind the enable gate (still budgets-only)
3. Update `exc-canary-disabled-enable-gate` evidence + flip status when signed
4. Only then follow `ops/runbooks/prebeta-demand-floor.md` re-enable checklist

**Approver for this NO-GO:** operator session 2026-08-07 (prebeta follow-ups).
Not a canary arm authorization.
