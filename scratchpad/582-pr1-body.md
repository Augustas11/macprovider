## Summary

**PR 1 of issue #582** — the coordinator core of the provider-onboarding deadlock fix. Gives operators a **durable, dual-control API to approve a `waiting_trust` hardware-verification job**, so a fresh/restored provider can reach `Ready` without SSH-ing into Pearl to hand-edit `stats-hardware-inventory.yaml` and wait on two systemd timers.

Closes the **primary deadlock** from #582 and its durability acceptance criterion. Referral-orthogonal (does not touch the #573–576 invite-gate cluster).

### The deadlock this removes
A provider's job parked in `hardware_verification_jobs.status='waiting_trust'` had **no operator API** — the only way to promote it was editing the YAML inventory + waiting for `stats-inventory-sync` + `stats-hardware-verifier` timers, and `stats-inventory-sync` *deleted* any out-of-band trust row on its next run (so durability was impossible).

### Mechanism
- **Dual-control `SECURITY DEFINER` trust approval** mirroring the existing `provider_auth_policy` pattern: new NOLOGIN `hardware_trust_definer/_requester/_approver` roles; `request_`/`approve_`/`revoke_hardware_trust_approval` functions owned by the definer. The coordinator's `provider_onboarding` role **never** gains write on `hardware_verification_trust` — the deliberate anti-fraud boundary (provider-submitted evidence must not auto-create trust roots) is preserved.
- Approval is **job-bound**: the tuple is derived server-side from an actual `status='waiting_trust'` job (locked, re-validated at approve time — status, `decision_reason='missing_trusted_hardware_identity'`, chip-profile presence, evidence + benchmark staleness, promotion runway), never operator-supplied.
- **Per-source trust rows** (`hardware_verification_trust` PK → `(provider_id, hardware_identity_hash, source)`): inventory-sync and operator-approval own independent rows, so operator approvals survive sync and neither authority clobbers the other. `stats-inventory-sync` deletes only `source='inventory'` rows.
- **Admission re-checks live trust**: `LatestVerified` (the hello gate) requires an *active* matching trust root, so a momentarily-stale `verified` bit can never admit revoked/expired hardware.
- **Session-lifecycle enforcement**: a successful revoke evicts the provider's active session (only when no active root of any source remains); a bounded 30s revalidation sweep evicts sessions whose trust lapsed; registration re-checks trust under the same advisory lock the SQL functions use.
- Endpoints: `POST /admin/hardware-trust/approve` + `/approve/{id}/approve` (dual-control), `POST /admin/hardware-trust/revoke`, `GET /admin/hardware-trust/waiting` (bounded, `approvable` flag).

### #582 acceptance criteria covered by this PR
- ✅ Fresh install reaches a terminal operator-visible state without SSH/manual DB edits (`Pending operator verification` → approve → `Ready`; `Not eligible` surfaced via actionable 4xx).
- ✅ Operator trust approval is **durable across `stats-inventory-sync.timer` runs**.
- ✅ No global disabling of `require_autotune_hello_gate` needed to onboard.

Deferred to follow-up PRs (tracked, not in scope here): CLI fallback-catalog pre-submission guard + actionable close-reason mapping (AC#3); Malibu onboarding-admission status states (AC#4), to be built on the shared `ProviderLifecycleState` enum in lockstep with #575.

## Audit

Money/security trust-path change → the mandatory 3-lane codex audit loop (code / security / architect), run to convergence. **0 CRITICAL every round.** Converged to **0 C / 0 H / 0 M on all three lanes** (security PASS, code PASS, architect PASS). The loop caught two runtime showstoppers a static suite can't (an ambiguous-column `42702` that would have failed *every* approval on Pearl; a `FOR SHARE` privilege gap), plus the trust-model race class (closed structurally via per-source rows + admission-time trust re-check), session-lifecycle enforcement, and deploy-safety ordering. Per-round prompts/artifacts under `audits/2026-07-16/`.

## ⚠️ Deploy prerequisites (rollout gated — do NOT promote to Pearl until these are done)

1. **Provision 3 NOLOGIN roles + logins**: `hardware_trust_definer` (NOLOGIN), `hardware_trust_requester`/`hardware_trust_approver` (`ALTER ROLE … LOGIN PASSWORD` from the secret store) — see `dist/hardware-trust-roles-bootstrap.sql`.
2. **Set two new DSNs**: `onboarding.hardware_trust_request_dsn` / `_approve_dsn` (env-indirected).
3. **Live-PostgreSQL smoke REQUIRED**: the in-repo suite has no live-PG harness for the `SECURITY DEFINER` functions (migration shape is string-asserted only; a Docker-gated coexistence integration test exists). Run a real `request → approve → revoke` round-trip against production-class PostgreSQL before promotion — this is called out in the migration header.

The deploy path (`deploy-pearl-vps.sh`) now self-applies migration 018 within a sidecar-quiesced window and **fails closed** (universal gate) if the 3-col schema isn't present when the new `stats-inventory-sync` binary would run, so a half-configured deploy aborts rather than silently breaking trust reconciliation.

## Carried residual (documented)
- **Verifier batch-ordering fairness** (`ProcessPending` `ORDER BY id LIMIT … SKIP LOCKED`): a large `waiting`/`pending` backlog can delay a now-approvable job. **Pre-existing** (unchanged by this branch; the prior YAML+sync path had identical behavior) — tracked separately, not a blocker.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
