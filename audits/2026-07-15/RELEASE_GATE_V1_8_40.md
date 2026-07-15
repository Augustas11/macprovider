# ACTIVE RELEASE GATE — v1.8.40 (Issue #585)

**Status:** OPEN — no v1.8.40 tag, release, or publication is authorized until
every item in the candidate proof gate passes on the exact prospective
artifacts.
**Supersedes:** the "Proposed no-release proof gate" section of
`ISSUE_585_HANDOFF.md` (historical snapshot in this directory).
**Normative basis:** `beta/DECISION_CRITERIA.md` entries 158–161.

## Three separately tracked gates

Issue #585 states are tracked as three independent gates. None implies the
others.

| Gate | Meaning | Status |
|---|---|---|
| G1 — implementation merged | v1.8.40 diff merged to main after the three-lane codex audit loop reaches 0 C/H/M | in progress (this branch) |
| G2 — exact candidate accepted | one signed, notarized candidate — byte-set identical in source to the prospective release — passes the full candidate proof gate below on the reachable Mac | not started |
| G3 — physical rollout complete | both Macs on latest CLI + latest Malibu, coordinator-connected, matrix + soak done | not started |

## Candidate proof gate (all items, exact prospective artifacts)

1. Verify signatures, notarization, stapling, release ledger, and
   compatibility-set identity.
2. Start from the true current states of the real machines (reachable Mac:
   CLI 1.8.30 + Malibu 1.8.39 + residual lifecycle test states; second Mac:
   handled separately under Entry 161 wipe path).
3. Exercise backend-first catalog/demand-rank handoff.
4. Use the already-installed real Qwen artifact (no fresh large acquisition
   inside the admission window).
5. Run the exact `serve --no-join --autotune-candidate` path, not a stub.
6. Prove every lifecycle transition and writer contract, including the
   candidate-scoped lifecycle store (candidate must not touch the incumbent's
   `state-v1.json`).
7. Prove launchd incumbent ownership before, during, and after cutover.
8. Force admission failure and prove restoration of binaries, config, launchd
   state, credentials, identity, model inventory, and the lifecycle
   file/absence per the transaction classes below.
9. Prove Malibu reflects the restored healthy incumbent (not candidate or
   intermediate transaction state) after rollback.
10. Prove successful activation, restart, reboot, coordinator reconnect, and
    durable operator-pause semantics.
11. Legacy-cohort safety: prove a connected v1.8.30 provider receives NO
    binary-only auto-update target from the v1.8.40 backend
    (capability-gated advertisement).
12. Complete the required soak before declaring G3 / closing Issue #585.

## Transaction boundary — three classes (per architect audit A-06)

The install transaction is NOT a universal filesystem rollback. Its contract
distinguishes:

1. **Exactly restored compatibility-set state** — binaries, config,
   provider_id, launchd plists, watchdog dir, install manifest,
   recommendation, and the lifecycle state file (contents-or-prior-absence,
   with the updater-owned-state translation rule of the A-01 fix).
2. **Reconciled supervisory state** — lifecycle lease (`lease.json`): cleared
   when owned by the rolled-back operation or a dead process, preserved for a
   live foreign owner; lock files preserved as synchronization primitives.
3. **Intentionally durable evidence** — logs/statistics, hash-qualified model
   cache, Keychain/bootstrap identity, coordinator-side admission evidence.
   These survive rollback by design and require post-rollback consistency
   checks, not restoration.

## Evidence ledger (updated as items complete)

| Item | Evidence | Date |
|---|---|---|
| Lifecycle edges pass on real candidate path | `testIntegrationRealServeLifecycleWhenEnabled` PASSED (real model, real binary) | 2026-07-15 |
| Full Swift suite | 1,355 tests, 0 failures, exit 0 | 2026-07-15 |
| Malibu app suite | 171 tests, 0 failures | 2026-07-15 |
| Installer rollback matrix | contents/absence/interrupted/forward cases green | 2026-07-15 |
| distribution suite | `make test-dist` full chain green | 2026-07-15 |
| Three-lane codex audit R1 | 0C/4H/5M/2L — fixes in progress | 2026-07-15 |
| G2 candidate run | — | pending |
| G3 rollout + soak | — | pending |
