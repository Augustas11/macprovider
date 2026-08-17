# Phase 3 live MDA — SPEC-008 v0.6 conformance vs R8 tip

**SPEC:** `specs/SPEC-008-tier2.md` v0.6.0 §7.3 / §7.9 / §7.10 / AC-C-11…18  
**Code tip:** `2e93d3c69f1b1b963fadca6efc7219b29bf2d270` (`audit/phase3-live-mda`)  
**Audit gate:** R8 APPROVE (`audits/2026-08-17/AUDIT_PHASE3_R8_SUMMARY.md`)  
**Date:** 2026-08-17

| AC / clause | Requirement (short) | Implementation | Tests / evidence | Verdict |
|-------------|---------------------|----------------|------------------|---------|
| §7.3 / AC-C-13 | Only live MDA publishes `hardware` | WS does not set hardware from `MDAHardware`; `SetMDAProof` only | `live_mda_test`, WS tier tests | **PASS** |
| AC-C-11 / §7.9.1 | No SE-serial MDM targeting | `RequestAndMaybeUpgrade` uses `LookupByProvider` only | device_binding_test borrow cases | **PASS** |
| AC-C-12 | No pending squat; enrolled+UDID | `ClaimDevice` + `ErrPendingClaimRejected`; EnrollmentStatus gate | ClaimDevice reject tests | **PASS** |
| §7.9.2 | Raw plist nonce enqueue | `EnqueueDeviceInformationAttestation` → `/v1/commands/{udid}` | client_test | **PASS** |
| §7.9.3 | acknowledge_event webhook | `ParseAcknowledgeEvent` + binding re-check | live_mda webhook tests | **PASS** |
| AC-C-14 | Webhook/cache current binding | webhook LookupByProvider; tryUpgradeFromCache serial match | R6/R5 regressions | **PASS** |
| AC-C-15 | Rebind clears hardware | `ClaimDevice` → `clearMDAProof` | `TestClaimDeviceClearsHardwareOnSerialRebind` | **PASS** |
| AC-C-16 | Durable proofs/pending/bindings; current AssignedID | `mda_store.go`; webhook Resolve current session | restart/reconnect tests | **PASS** |
| AC-C-17 | ≥168h floor + atomic ledger | config floor; reserve-before-HTTP | config_env_test; concurrent enqueue | **PASS** |
| AC-C-18 / §7.10 | Observe only; no require_attestation flip | live MDA failures log-only; no flip in Phase 3 code | R8 architect | **PASS** |
| §7.10 | Phase 4 prereqs not claimed done | SPEC explicit; runbook Phase 4 unchecked | n/a (boundary) | **PASS** (doc) |

**Gaps / forward (not Phase 3 blockers):**
- Pearl live E2E still open in runbook (§3.2 manual Mac checklist).
- Buyer field naming (`hardware_attestation`) / further disclosure polish remain forward;
  coordinator already gates positive counts on `attestation_tier=hardware` (#759, pre-v0.6) —
  Phase 3 did not claim to close that counting gap (§7.10.4).
- `require_attestation` still admits `self_signed` (§7.6 / §7.10.3) — intentional until a future hardware-gated predicate SPEC.

**Overall conformance (code ↔ §7.9):** **MATCH** at R8 tip for normative Phase 3 clauses above.
