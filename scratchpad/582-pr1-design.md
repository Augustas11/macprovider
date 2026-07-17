# Issue #582 — PR 1 design (locked)

**Scope:** Durable operator hardware-trust approval path — closes the primary
onboarding deadlock (`waiting_trust` with no operator API) and AC#2 (durable
across `stats-inventory-sync`). Referral-orthogonal (#573–576 untouched).

## Root cause (from recon)
- A provider's `hardware_verification_jobs` row parks in `status='waiting_trust'`
  (`internal/stats/hardwareverify/verify.go:383`) until an operator hand-edits
  `trusted_hardware:` in `/etc/macprovider-stats/stats-hardware-inventory.yaml`,
  waits for `stats-inventory-sync.timer` to write `hardware_verification_trust`,
  then waits for `stats-hardware-verifier.timer` to promote the job. **No HTTP/admin
  API exists** to approve a `waiting_trust` job.
- `stats-inventory-sync` `applyTrustInventory` (`cmd/stats-inventory-sync/main.go:568`)
  does `DELETE FROM hardware_verification_trust WHERE NOT (key = ANY(yaml_keys))`
  every run → any out-of-band trust row is wiped on the next timer.

## Deliberate security boundary (must preserve)
The coordinator's `provider_onboarding` DB role can queue evidence + SELECT the
trust table but is NOT granted write on `hardware_verification_trust`. A trigger
(`hardware_verification_jobs_guard_verifier_update`) + `current_user = 'provider_onboarding'`
guard prevent self-promotion. Anti-fraud: provider-submitted evidence must not
auto-create trust roots. **Do not grant the coordinator raw trust-table write.**

## Design: mirror `provider_auth_policy` dual-control exactly
Pattern source: `internal/stats/migrations/006_spec_026_identity.up.sql` lines
258–475 (request/approve SECURITY DEFINER fns + roles + grants) and `009_...up.sql`.

- `source TEXT NOT NULL DEFAULT 'inventory' CHECK (source IN ('inventory','operator_api'))`
  on `hardware_verification_trust`.
- Sync `applyTrustInventory`: set `source='inventory'` on upsert; scope its DELETE
  to `... AND source = 'inventory'` so operator_api rows survive.
- New tables `hardware_trust_pending` + `hardware_trust_grants` (mirror
  `provider_auth_policy_pending`/`_grants`, incl. `CHECK (approved_by <> requested_by)`).
- SECURITY DEFINER fns `request_hardware_trust_approval(...)` /
  `approve_hardware_trust_approval(...)` owned by new NOLOGIN role
  `hardware_trust_definer`; EXECUTE granted to `hardware_trust_requester` /
  `hardware_trust_approver`. On approve, INSERT a `source='operator_api'` row into
  `hardware_verification_trust` for the job's (provider_id, hardware_identity_hash,
  chip_normalized, unified_memory_gb). Existing verifier timer then promotes the
  job through its NORMAL validation — no bypass.
- Coordinator: separate request/approve DB handles (mirror `authPolicyRequestDB`/
  `authPolicyApproveDB`), new DSNs `onboarding.hardware_trust_request_dsn` /
  `_approve_dsn`, dual-control endpoints `POST /admin/hardware-trust/approve` +
  `/admin/hardware-trust/approve/{id}/approve`, and read endpoint
  `GET /admin/hardware-trust/waiting` (list `waiting_trust` jobs — none exists today).

## Deploy dependency (flag in PR body)
New NOLOGIN roles need Pearl provisioning (`ALTER ROLE ... LOGIN PASSWORD` from
secret store) + the two new DSNs in coordinator config before deploy. Code merges
independently; rollout gated on provisioning.

## Follow-up PRs (not this one)
- PR2 CLI: refuse autotune evidence submission when `usedFallback=true`
  (`AutotuneHardwareEvidence.swift:28`); map `autotune_evidence_required/_invalid`,
  `catalog_incompatible` close reasons to actionable lifecycle states
  (`CoordinatorClient.swift:1372` allow-list gap). AC#3.
- PR3 Malibu: add onboarding-admission cases to shared `ProviderLifecycleState`
  enum — coordinate with #575 (shared surface). AC#4.
- AC#5 (no global gate disable) satisfied once PR1 gives per-provider approval.
