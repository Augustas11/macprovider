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
| 2. Autotune evidence | Stranger / installer | `macprovider-cli autotune --recommend` loads the **signed live** candidate catalog, probes, and submits hardware evidence | If only the baked catalog is available, CLI **fail-closes before submit/apply** with actionable copy (offline `--no-submit-hardware-evidence` diagnostics remain allowed) |
| 3. Trust park | Pearl | Verifier parks unknown hardware as `waiting_trust` | **Pending hardware verification** |
| 4. Operator approve | Operator | Dual-control admin API (below) — durable `source=operator_api` trust root | Still **Pending hardware verification** until verifier promotes |
| 5. Verifier promote | Pearl | `stats-hardware-verifier` moves job → `verified` when trust is live | Waiting for network approval → reconnect |
| 6. Admit / serve | Pearl + CLI | Hello gate accepts verified evidence against the **live** catalog SHA; provider heartbeats | **Provider is ready** |

Other supported terminals (no gate disable):

- **Not eligible: admission evidence failed** — verified evidence fails the live catalog / model-cap gate (`autotune_evidence_invalid`, `autotune_model_cap_exceeded`). Cap exceeded requires applying a smaller admitted model; invalid evidence needs a fresh signed recommendation.
- **This Mac is not currently eligible** — uncatalogued model (`autotune_model_uncatalogued`) or catalog/software update required.
- Identity / signing setup remains under the existing repair paths (out of scope for this runbook).

## Operator trust approval (no YAML / DB edits)

Prerequisites (Pearl): migration 019, hardware-trust roles/DSNs provisioned
(`dist/hardware-trust-roles-bootstrap.sql`, `ONBOARDING_HARDWARE_TRUST_*_DSN`).
See PR #627 deploy notes.

Run requester and approver steps from **separate operator sessions/hosts**. Feed
Authorization headers through curl `--config -` so bearer values do not appear
in process argv.

List jobs parked on missing trusted hardware. Only rows with
`"approvable": true` can be dual-control approved (chip profile present and
promotion runway intact). Non-approvable `waiting_trust` rows need chip-profile
/ inventory remediation first — they are visible but not part of the stranger
API path.

```bash
{
  printf '%s\n' 'url = "https://coordinator.streamvc.live/admin/hardware-trust/waiting?limit=50"'
  printf '%s\n' "header = \"Authorization: Bearer ${OPERATOR_TOKEN}\""
} | curl --silent --show-error --fail-with-body --config -
```

Dual-control approve (requester ≠ approver). The approve-confirm endpoint
requires a JSON body (`{}` is valid). Use `printf '%s\n'` so JSON quotes are
not consumed by bash `printf` escapes.

```bash
# Requester (separate session)
JOB_ID=12345   # numeric job_id from an approvable waiting_trust row
{
  printf '%s\n' 'url = "https://coordinator.streamvc.live/admin/hardware-trust/approve"'
  printf '%s\n' 'request = "POST"'
  printf '%s\n' "header = \"Authorization: Bearer ${REQUESTER_TOKEN}\""
  printf '%s\n' 'header = "Content-Type: application/json"'
  printf '%s\n' "data = \"{\\\"job_id\\\":${JOB_ID},\\\"reason\\\":\\\"operator approved waiting_trust job\\\"}\""
} | curl --silent --show-error --fail-with-body --config -

# Approver (separate session; PENDING_ID from request response)
{
  printf '%s\n' "url = \"https://coordinator.streamvc.live/admin/hardware-trust/approve/${PENDING_ID}/approve\""
  printf '%s\n' 'request = "POST"'
  printf '%s\n' "header = \"Authorization: Bearer ${APPROVER_TOKEN}\""
  printf '%s\n' 'header = "Content-Type: application/json"'
  printf '%s\n' 'data = "{}"'
} | curl --silent --show-error --fail-with-body --config -
```

Do **not**:

- Edit `hardware_verification_jobs` or `hardware_verification_trust` by hand
- Edit `/etc/macprovider-stats/stats-hardware-inventory.yaml` as the only trust path for strangers (inventory remains for fleet inventory sync; operator API is the stranger onboarding authority)
- Disable `proof_of_weights.require_autotune_hello_gate` to “unblock” one provider

## CLI / Malibu surfaces (#582 follow-up)

Onboarding outcomes keep lifecycle **v1 wire states** and distinguish via
`reason_code` so older Malibu readers remain valid.

| Reason code | Lifecycle state (v1) | Public title |
|-------------|----------------------|--------------|
| `autotune_evidence_required` | `coordinator_unavailable` | Pending hardware verification |
| `autotune_evidence_invalid` / `autotune_model_cap_exceeded` | `catalog_incompatible` | Not eligible: admission evidence failed |
| `autotune_model_uncatalogued` | `catalog_incompatible` | This Mac is not currently eligible |
| Catalog fallback on recommend+submit/apply | n/a | Fail closed — signed live catalog unavailable… cannot be submitted |

## Physical acceptance (still required to close #582)

Code + this runbook document the no-exception path. Closing #582 still needs a
**physical** fresh/restored install that reaches Ready (or an explicit supported
terminal) with audits merged and without temporary auth/catalog exceptions.
Record that journey separately; do not mark #582 closed from this document alone.
