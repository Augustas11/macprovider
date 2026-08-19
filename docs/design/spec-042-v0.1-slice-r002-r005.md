# SPEC-042 v0.1 — Build slice: R002 `pool_id` threading + R005 fail-closed isolation

Status: design (drives the first implementation slice). Tests-first.
Reference: `specs/SPEC-042-pool-control-plane.md` (v0.0.7). Tracks #1053.

This slice implements the two deploy-blocking primitives — a `pool_id` authority
field and fail-closed tenant isolation — with the minimum pool substrate needed
to test isolation. Manifest signing (R001), predicates (R004), settlement labels
(R006), promise surfaces (R008), lifecycle (R011), and key lifecycle (R012) are
**out of this slice**; where they are needed to test isolation they are stubbed
(an in-memory pool registry seeded directly), not implemented.

## Decision — Open-A: `pool_id` representation = **nullable, no sentinel**

`pool_id` is represented as an **absent/NULL** value for global (poolless)
traffic on the wire, in every struct, and in every storage column — NOT a
reserved sentinel string.

Rationale:
- Global traffic MUST behave exactly as today (SPEC-042-R002/R010). A nullable
  field defaults to NULL for all existing rows/requests: zero backfill, zero
  behavior change, additive migration.
- A sentinel would force every global-path comparison to special-case it and
  risks a sentinel collision being misread as a pool. Nullable makes "no pool →
  existing global path, never a pool fallback" the structural default.
- Matches the SPEC's "representation-only, MUST NOT reopen whether global is a
  pool" framing.

Wire/type: `pool_id *string` (Go pointer, nil = global) on request structs;
`pool_id TEXT NULL` (or equivalent) on route-snapshot / request-log / settlement
rows. `pool_generation *uint64` travels with a non-nil `pool_id`.

## Minimal pool substrate for this slice (stub, not R001/R012)

An in-memory `PoolRegistry` keyed by `pool_id`, reconstructable from durable
storage later, exposing exactly what R005 needs:

- `Members(poolID) -> set[providerIdentity]` — current admitted members.
- `Generation(poolID) -> uint64` — bumped on any membership/revocation/lifecycle
  change; captured together with the member set in a single consistent read
  (SPEC-042-R003 TOCTOU rule).
- `IsRevoked(poolID, providerIdentity) -> bool` — durable per-pool blocklist.
- `Exists(poolID) -> bool`.

For this slice the registry is seeded directly in tests (`AddPool`,
`AddMember`, `Revoke`), so isolation can be exercised without manifests/signing.
Durable tables (`pools`, `pool_members`, `pool_revocations`) are defined here but
their write path from a signed manifest is R001's slice.

## R002 — `pool_id` threading map

`pool_id` (nullable) enters at the gateway from the **credential-authorized**
selection source (R002 authorization: bound to API-key/wallet-session scope,
route param may only narrow), and is carried unmodified through:

1. gateway request → coordinator request struct  *(seam: TBD from code map)*
2. coordinator route context / route decision      *(seam: buyer route selection)*
3. route snapshot row (`pool_id`, `pool_generation`, `manifest_version` NULL for now)
4. request log row (`pool_id`)
5. settlement context (label only; R006 disposition deferred)

A request MUST NOT be reassigned pool→global or pool→pool after admission.
Selection-authorization enforcement (narrow-only, unauthorized→`pool_unavailable`)
is included; wallet-session `pool_id` binding needs a SPEC-040 amendment
(R010 gate) so this slice supports **API-key-scoped pools only**, wallet-scoped
pools deferred.

*(Exact function/struct seams filled from the R002/R005 code-integration map.)*

## R005 — fail-closed isolation + generation fence

At **every** dispatch-authorizing decision (ordinary selection, failover, sticky
retry, hard/pinned/self-route, slot-queue):

```
if req.pool_id != nil:
    (members, gen) := registry.SnapshotConsistent(req.pool_id)   # single read
    candidates := members
        .filter(not revoked)
        .filter(serving-capable / predicates)          # predicates minimal this slice
    if candidates.empty:
        if any member exists but all at capacity: fail pool_at_capacity
        else: fail pool_no_eligible_member              # NO spill to global/other pool
    stamp route decision with (pool_id, gen)
else:
    existing global selection, unchanged
```

At dispatch, verify the fenced `gen` still equals the live pool generation; on
mismatch → `pool_state_stale`, force fresh selection. The pinned/self-route path
(which bypasses the eligibility choke-point today) MUST be routed through the
same member+generation check, not a hand-copied gate.

Invariant under test: **a request bearing `pool_id=P` is never dispatched to a
non-member, another pool's member, or global supply, and fails closed when P has
no eligible member.**

## Isolation conformance-test matrix (write FIRST, must fail before impl)

| # | Scenario | Assertion |
|---|---|---|
| T1 | pool P = {X,Y}, non-member Z present; request pool_id=P | selects X or Y; never Z; never global |
| T2 | pool P, all members removed/unavailable; Z + global present | fail closed `pool_no_eligible_member`; no spill |
| T3 | global request (pool_id=nil) with Z + global present | unchanged today's behavior (may select any global) — no regression |
| T4 | member X revoked at T; request at T+ε | never selects X (gen-keyed eligibility; not a 5s window) |
| T5 | request pool_id=P pinned to non-member Z | rejected (pinned provider not a member); no dispatch to Z |
| T6 | failover: first member fails mid-select | failover re-applies member filter; never non-member/global |
| T7 | reservation fenced at gen g; membership change → gen g+1; dispatch | `pool_state_stale`; fresh selection required |
| T8 | pool P members all at capacity | `pool_at_capacity` (not `pool_no_eligible_member`); no spill |
| T9 | unauthorized credential names pool P (route param widening) | `pool_unavailable`; latency independent of P existence |

T1–T8 target R005; T9 targets R002 authorization. Each MUST fail (red) before
implementation, then pass (green) after.

## Slice boundaries (explicitly deferred)

- Manifest parsing/signing, predicates enforcement detail, wallet-scoped pools,
  settlement-label disposition write path, promise surfaces, lifecycle machine,
  key lifecycle — separate slices.
- Canonical byte-grammar / JSON schemas / retention matrix — v0.1 detailed-design
  deliverables gated in R010, not required to land the isolation invariant.
