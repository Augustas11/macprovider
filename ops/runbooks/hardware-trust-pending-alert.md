# Hardware trust pending — operator alert (prebeta P4)

**Goal:** Cut trust-grant latency from “whenever an operator next looks” to minutes.

## Signals

### A. Journal line (preferred)

`stats-hardware-verifier` emits when a job is parked `waiting_trust`:

```text
hardware_trust_waiting_new job_id=123 provider_id=mp-… reason=missing_trusted_hardware_identity
```

**BetterStack (or journald ingest):** match `hardware_trust_waiting_new`, dedupe on `job_id`, page on-call.

### B. Admin poll (backup)

```bash
curl -sS -H "Authorization: Bearer $OPERATOR_TOKEN" \
  https://coordinator.streamvc.live/admin/hardware-trust/waiting | jq '.count, .waiting_trust'
```

Cron every 5 minutes; alert when `count > 0` for >5 minutes.

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
