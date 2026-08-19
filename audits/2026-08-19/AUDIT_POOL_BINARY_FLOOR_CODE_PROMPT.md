# Codex audit — SPEC-042 pool binary-version floor — CODE lane

Money-path/tenant-isolation change to the MacProvider coordinator (phase4, Go).
Review the FULL slice diff as it will land.

Diff: `audits/2026-08-19/pool-binary-floor-fulldiff.patch` (base = the commit
before this slice; the slice is one commit on current main). Read the changed
source in the worktree. Design: `docs/design/spec-042-v0.1-slice-pool-binary-floor.md`.
Spec: `specs/SPEC-042-pool-control-plane.md` (R004 predicates, R010 taxonomy +
positive capability handshake, R005 fence).

## What the slice does
Completes the R010 handshake provider half: a pool request must never be routed
to a pool member whose `binary_version` is below the pool's configured minimum.
Under-version members are excluded on every dispatch-authorizing path; if none
remain the request fails closed with `pool_binary_too_old` (503, non-retryable),
never spilling to an under-version or global provider. Coordinator-only; reuses
the provider's existing `binary_version` handshake.

Key sites:
- `internal/trustpool/registry.go` — per-pool `minBinaryVersion`, `Snapshot.MinBinaryVersion`, `SetMinBinaryVersion` (bumps generation).
- `internal/routing/filter.go` — `ReasonPoolBinaryTooOld` + `ProviderMeetsPoolBinaryFloor` gate (after `ProviderInPool`, before model gates).
- `internal/buyer/server.go` — `eligibilityCtx`/`forwardState` carry the floor; the gate is re-applied on the pinned-session, pinned/self-route, slot-queue-enter, and slot-queue-poll by-hand paths; `poolBinaryFloorMet` helper; envelope + error registration.

## Focus (Critical/High/Medium/Low/Info, file:line + concrete failing scenario)
1. Correctness of `poolBinaryFloorMet`: any version pair (empty, `v`-prefixed, malformed, extra components, floor==provider) where the verdict is WRONG — a below-floor member served, or an at/above-floor member wrongly excluded. Confirm empty/unparseable is fail-safe (excluded) and floor=="" is a strict no-op.
2. **Path coverage** — is the floor applied on EVERY dispatch-authorizing path, matching the isolation gate exactly? Any path (retry, failover, sticky, preflight replacement, mid-request provider loss) where an under-version member can still be dispatched. A miss here is the whole point of the slice.
3. Snapshot consistency: floor read from the SAME snapshot as members/generation; `SetMinBinaryVersion` bumps generation so a raised floor invalidates fenced reservations. Any TOCTOU where the floor and membership diverge.
4. Error taxonomy: `pool_binary_too_old` 503/non-retryable matches the R010 table; registered so the AST guard passes; envelope precedence vs `pool_no_eligible_member` and the model floor is correct (member-but-under-version vs no-member vs model-floor); membership dominates (a non-member is never reported too-old).
5. Any nil-deref, concurrency issue (registry lock), or global/poolless behavior change introduced.
6. Test adequacy: do the tests actually prove non-dispatch on the fail-closed paths and byte-identical global/floorless, or pass vacuously?

Be adversarial and concrete. State the exact input and wrong result for any finding. Report 0 findings if clean.
