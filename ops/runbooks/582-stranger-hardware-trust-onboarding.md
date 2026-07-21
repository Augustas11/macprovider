# #582 — Supported stranger onboarding (no-exception path)

End-to-end path for a fresh Malibu / `macprovider-cli` install that reaches a
terminal **user-visible** state without SSH, manual Postgres edits, temporary
`proof_of_weights.require_autotune_hello_gate=false`, or other production
exceptions.

Related: issue [#582](https://github.com/Augustas11/macprovider/issues/582),
PR [#627](https://github.com/Augustas11/macprovider/pull/627) (durable operator
hardware-trust API), Malibu public-status shell (#655).

## Supported path (stranger → ready)

| Step | Actor | What happens | User-visible terminal (if stuck) |
|------|-------|--------------|----------------------------------|
| 1. Install | Stranger | Installer / Malibu bootstrap installs CLI + config | Model is preparing |
| 2. Autotune evidence | Stranger / installer | `macprovider-cli autotune --recommend` (optionally `--apply`) loads the **signed live** candidate catalog, probes, and submits hardware evidence | If the signed catalog feed is unreachable, CLI **fail-closes** before submit with actionable copy (no baked-catalog evidence) |
| 3. Trust park | Pearl | Verifier parks unknown hardware as `waiting_trust` | **Pending hardware verification** |
| 4. Operator approve | Operator | Dual-control admin API (below) — durable `source=operator_api` trust root | Still **Pending hardware verification** until verifier promotes |
| 5. Verifier promote | Pearl | `stats-hardware-verifier` moves job → `verified` when trust is live | Waiting for network approval → reconnect |
| 6. Admit / serve | Pearl + CLI | Hello gate accepts verified evidence against the **live** catalog SHA; provider heartbeats | **Provider is ready** |

Other supported terminals (no gate disable):

- **Not eligible: admission evidence failed** — verified evidence exists but fails the live catalog / admission gate (`autotune_evidence_invalid`). Fix: refresh signed recommendation online, then restart.
- **This Mac is not currently eligible** — software / catalog update required, or other non-buyer-serving network state.
- Identity / signing setup remains under the existing repair paths (out of scope for this runbook).

## Operator trust approval (no YAML / DB edits)

Prerequisites (Pearl): migration 019, hardware-trust roles/DSNs provisioned
(`dist/hardware-trust-roles-bootstrap.sql`, `ONBOARDING_HARDWARE_TRUST_*_DSN`).
See PR #627 deploy notes.

List jobs parked on missing trusted hardware:

```bash
curl -sS -H "Authorization: Bearer ${OPERATOR_TOKEN}" \
  "https://coordinator.streamvc.live/admin/hardware-trust/waiting"
```

Dual-control approve (requester ≠ approver):

```bash
# Requester
curl -sS -X POST -H "Authorization: Bearer ${REQUESTER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"job_id":JOB_ID,"reason":"operator approved waiting_trust job"}' \
  "https://coordinator.streamvc.live/admin/hardware-trust/approve"

# Approver (use pending id from request response)
curl -sS -X POST -H "Authorization: Bearer ${APPROVER_TOKEN}" \
  "https://coordinator.streamvc.live/admin/hardware-trust/approve/${PENDING_ID}/approve"
```

Do **not**:

- Edit `hardware_verification_jobs` or `hardware_verification_trust` by hand
- Edit `/etc/macprovider-stats/stats-hardware-inventory.yaml` as the only trust path for strangers (inventory remains for fleet inventory sync; operator API is the stranger onboarding authority)
- Disable `proof_of_weights.require_autotune_hello_gate` to “unblock” one provider

## CLI / Malibu surfaces (#582 follow-up)

| Lifecycle / reason | Public title |
|--------------------|--------------|
| `pending_hardware_verification` / `autotune_evidence_required` | Pending hardware verification |
| `hardware_evidence_rejected` / `autotune_evidence_invalid` | Not eligible: admission evidence failed |
| Catalog fallback warning on recommend | Fail closed — signed live catalog unavailable… rejected before submission |

## Physical acceptance (still required to close #582)

Code + this runbook document the no-exception path. Closing #582 still needs a
**physical** fresh/restored install that reaches Ready (or an explicit supported
terminal) with audits merged and without temporary auth/catalog exceptions.
Record that journey separately; do not mark #582 closed from this document alone.
