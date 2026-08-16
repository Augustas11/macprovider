# Hardware trust pending — operator alert (prebeta P4)

**Goal:** Cut trust-grant latency from “whenever an operator next looks” to minutes.

## Signals

### A. Journal line

`stats-hardware-verifier` emits when a job is parked `waiting_trust`:

```text
hardware_trust_waiting_new job_id=123 provider_id=mp-… reason=missing_trusted_hardware_identity
```

### B. Pearl Gmail monitor (live path)

BetterStack is **not** the live Pearl page path. Pearl pages via
`macprovider-monitor` → Gmail (`/etc/macprovider/monitor.env`, timer every 3 min).

`phase4-coordinator/dist/monitor/macprovider-monitor.py` polls
`GET /admin/hardware-trust/waiting` with `OPERATOR_AUTH_POLICY_A` (or `_B`) and emails kind
`hardware_trust` (not in the default mute list) when:

1. A **new** `job_id` appears → `hardware_trust_waiting_new …`
2. Backlog persists ≥ `HARDWARE_TRUST_WAITING_STALE_MINUTES` (default 5) →
   `hardware_trust_waiting_stale count=…`

Deploy: copy the updated `macprovider-monitor.py` to the unit’s `ExecStart`
path, then `systemctl start macprovider-monitor.service` once to verify.

Optional env:

```bash
HARDWARE_TRUST_WAITING_ENABLED=1
HARDWARE_TRUST_WAITING_STALE_MINUTES=5
```

### C. Manual admin poll

```bash
curl -sS -H "Authorization: Bearer $OPERATOR_TOKEN" \
  https://coordinator.malibu.tech/admin/hardware-trust/waiting | jq '.count, .waiting_trust'
```

## In-app copy (Malibu)

Pending state: **“Hardware verification pending — usually under an hour.”**

## Grant path (unchanged trust model)

1. `GET /admin/hardware-trust/waiting`
2. Dual-control request + approve (`POST …/approve`, `POST …/approve/{id}/approve`)
3. Do **not** auto-grant; alert + visible ETA only

## Related

- Issue #838 (fatal install path closed; wait remains)
- `phase4-coordinator/internal/stats/hardwareverify/verify.go`
- `phase4-coordinator/internal/ws/admin_hardware_trust.go`
- `scripts/test-macprovider-monitor-hardware-trust.py`
