# Prebeta demand floor (P5) — gated by #584

**Status:** Prepared, **not armed** on Pearl.

## Why gated

Production exception `exc-canary-disabled-enable-gate` (#584) keeps:

- `/var/lib/macprovider-canary-buyer/DISABLED` present
- `/etc/macprovider-canary-buyer/enabled` absent
- `pool.canary_enabled: false`
- `canary-buyer.timer` disabled

Until #584 physical baselines + signed go/no-go land, do **not** remove `DISABLED` or create the enable gate.

## What “demand floor” means for provider UX

Every online eligible provider should see a buyer request at least every few minutes so Malibu request + USD counters move. At ~45 req/day, most of a 5-node fleet sits idle for hours.

## Re-enable checklist (after #584 approval)

```bash
# 1. Confirm signed go/no-go + physical baselines on record
# 2. Coordinator overlay
ssh pearl 'sudo sed -i "s/canary_enabled: false/canary_enabled: true/" /etc/macprovider/coordinator.pearl-overlays.yaml'
# 3. Remove emergency sentinel, install enable gate
ssh pearl 'sudo rm -f /var/lib/macprovider-canary-buyer/DISABLED
  && sudo install -d -o root -g root -m 0755 /etc/macprovider-canary-buyer
  && sudo touch /etc/macprovider-canary-buyer/enabled
  && sudo systemctl daemon-reload
  && sudo systemctl enable --now canary-buyer.timer'
# 4. Watch pool health for 1h; emergency rollback:
#    ops/runbooks/584-emergency-disable-drill.md
```

Keep canary in **liveness** budgets only (≤4 req / 32 tokens / 90s); `CANARY_DEGRADED_RETRIES=0`.

## Interim (until canary returns)

- **P1** adaptive USD + eligibility copy (ready/$0 honesty)
- **P2** MALIBU emission ticks (counter motion without buyer demand)
- Do not invent a second unapproved buyer probe that bypasses #584

## Related

- `ops/exceptions/production-exceptions.json` → `exc-canary-disabled-enable-gate`
- `ops/runbooks/584-physical-baseline-matrix.md`
- `test/e2e/canary-buyer/README.md`
