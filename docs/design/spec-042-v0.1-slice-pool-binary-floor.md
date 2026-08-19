# SPEC-042 v0.1 slice — pool provider binary-version floor (R010 handshake, provider half)

Status: design → implementation. Coordinator-only (phase4). Stacked on main
(the SPEC-042 Layer 2 stack landed 2026-08-19).

## 1. What this slice delivers (SPEC-042 R010 provider half + R004 min-binary predicate)

R010 requires a **positive pool-capability negotiation**: a pool-required request
MUST NOT be served unless BOTH the coordinator AND the selected provider
positively support pools at the required version — otherwise a mixed-binary
rollout can spill pool traffic to a pool-blind provider. The gateway slice
(#1076) built the coordinator-advertises-to-gateway half. This slice builds the
provider half, entirely inside the coordinator (the gateway can't see the
selected provider, so the coordinator must enforce it).

A provider already advertises its capability: it sends `binary_version` in the
WebSocket `hello` handshake, landing on `pool.Provider.BinaryVersion`. So the
provider half is an **eligibility gate**, not a new wire protocol:

> A pool member is eligible for pool *P*'s traffic only if its `binary_version`
> meets *P*'s configured minimum. A member below the floor is excluded from pool
> routing on **every** dispatch-authorizing path; if that leaves no eligible
> member, the request fails closed with `pool_binary_too_old` (503,
> non-retryable) — never spilling to an under-version or global provider.

This is the SPEC-042-R004 "minimum signed provider binary version" predicate,
enforced fail-closed, satisfying the R010 provider advertisement (a provider's
binary version *is* its capability signal). No provider/Swift change, no release.

### Out of scope (deferred, documented)
- A dedicated `pool_support_version` handshake field decoupled from binary
  version (Option B) — only needed if pool-protocol support must rev
  independently of the binary. Not needed while binary version is the capability.
- The signed manifest as the floor source (R001) — the floor is per-pool
  registry state now; it moves into the manifest policy core when R001 lands.
- Other R004 predicates (encrypted-leg, attestation tier, model-hash) — separate
  slices; this one is binary-version only.

## 2. Where the floor lives — per-pool, in the consistent snapshot

The floor is a per-pool value on `trustpool` `poolState.minBinaryVersion`,
exposed on `Snapshot.MinBinaryVersion`, read under the **same single lock** as
`Members`/`Generation`. Rationale: it must be part of the R003 consistent
snapshot so a route attempt evaluates membership AND floor against one coherent
view. A new `SetMinBinaryVersion(poolID, version)` **bumps the generation** (like
`AddMember`/`Revoke`), so raising a pool's floor invalidates in-flight
reservations via the existing generation fence — the raised floor applies at
once instead of leaking a TTL window of under-version dispatch.

`selectProviderExcluding` reads `snap.MinBinaryVersion` alongside `poolMembers`
/`poolGeneration` (server.go ~5577) and threads it into `eligibilityCtx` and
`forwardState`, exactly mirroring the membership threading.

## 3. The gate (pure, fail-safe)

```
func meetsPoolBinaryFloor(providerVersion, floor string) bool {
    if floor == "" { return true }                 // no floor configured → inert
    cmp, ok := versionfloor.Compare(providerVersion, floor)
    return ok && cmp >= 0                            // empty/malformed version → excluded
}
```

- `floor == ""` (no minimum configured for the pool) → **total no-op**, byte-identical to today.
- Empty or non-numeric `BinaryVersion` while a floor is in force → `Compare` returns `ok=false` → **excluded** (fail-safe, mirroring the #768 malformed-version posture and the global admission floor at `ws/server.go:2417`).
- `versionfloor.Compare` is the coordinator's single canonical comparator (dotted numeric, optional `v` prefix). The configured floor is validated with `versionfloor.Valid` at seed time.

## 4. Enforcement on every dispatch-authorizing path

Membership dominates: a non-member is reported `pool_not_member` and never also
evaluated for the floor. Placement mirrors the isolation gate exactly.

| Path | Site | Add |
|---|---|---|
| Ordinary filter | `routing/filter.go` after the `ProviderInPool` stanza | `if !checker.ProviderMeetsPoolBinaryFloor(p) { Counts[ReasonPoolBinaryTooOld]++; continue }` |
| Pinned session | `server.go` ~5593 (after member check) | `else if poolActive && !meetsFloor(p) { return pool_binary_too_old }` |
| Pinned/self-route | `server.go` ~5614 | same |
| Slot-queue enter (`slotQueueCandidates`) | uses the checker | add `&& checker.ProviderMeetsPoolBinaryFloor(provider)` |
| Slot-queue poll (`pollQueuedProvider`) | ~6576 (uses `state.poolMembers`) | also check the floor from `state.poolMinBinaryVersion` |

New checker method `ProviderMeetsPoolBinaryFloor(p pool.Provider) bool` on
`EligibilityChecker`; `eligibilityCtx` impl returns true when
`poolID == "" || poolMinBinaryVersion == ""`, else the gate above.

## 5. Error taxonomy — `pool_binary_too_old` (R010)

503, **non-retryable**, authorized-only visibility (returned only for a
credential-authorized pool selection, so revealing "binary too old" is fine).
Register identically to the two existing pool codes:
- `spec018RetryableByCode`: `"pool_binary_too_old": false`
- `coordinatorEmittedErrorCodes` (test inventory): append
- The AST guard then passes automatically once the literal is emitted.

Ordinary-path reason→envelope mapping: when the filter leaves no candidate and
`Counts[ReasonPoolBinaryTooOld] > 0` (members exist but all under-version) →
`pool_binary_too_old`; a pool with no members at all stays
`pool_no_eligible_member`. `pool_binary_too_old` is ordered after the
member-specific check, before the generic no-provider error.

## 6. Compatibility
- No pool floor configured → gate is a strict no-op; pool routing unchanged.
- Global (poolless) traffic → `poolActive` false → untouched, byte-identical.
- Provider binary/handshake → **unchanged** (reuses the existing `binary_version`).
- Default-off preserved: `trustPools == nil` → no pool paths execute at all.

## 7. Test plan (conformance-first, mirror `spec042_pool_isolation_test.go`)
- `poolProvider` variant that sets `BinaryVersion`; below-floor member excluded on the filter path, the pinned path, and the slot-queue path.
- All-members-under-floor → `pool_binary_too_old`, non-retryable, no spill (no dispatch).
- At/above-floor member → served (passes the gate).
- Empty `BinaryVersion` under a configured floor → excluded (fail-safe).
- No floor configured (`""`) → gate inert, member served regardless of version.
- Global (no pool) request → floor never consulted; byte-identical.
- `SetMinBinaryVersion` bumps the generation → an in-flight reservation fenced to the old generation is stale (`poolGenerationStale`), so a raised floor re-selects.
- Membership dominates: a non-member under floor reports `pool_not_member` (not `pool_binary_too_old`).
