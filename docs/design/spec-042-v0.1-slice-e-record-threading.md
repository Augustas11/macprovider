# SPEC-042 v0.1 — Build slice E: pool_id record-site threading (money-path)

Status: design (drives the Stage E implementation). Tests-first. Money-path →
must pass the codex three-lane audit (code/security/architect) to 0 C/H/M
before merge. Stacks on the R002/R005 impl (PR #1069). Reference:
`specs/SPEC-042-pool-control-plane.md` R002/R006. Tracks #1053.

## Scope
Record the selected `pool_id` (nullable; "" = global) into the two coordinator
DB records R002 names, without changing money-path arithmetic or global
behavior:

1. `request_log.pool_id` — pure observability label (additive nullable column).
2. `settlement_route_snapshots.pool_id` — the settlement/route-snapshot context
   binding (SPEC-042 R006), so a pool request's settlement record carries and
   is bound to its pool.

Out of scope: creator revenue-split execution (deferred to the SPEC-005/016
V1), the provider-signed v0.4 receipt tuple (unchanged — R002 binds
route-snapshot/settlement context only, NOT the receipt tuple, unless SPEC-015
is revised), gateway auth/emit.

## Hard invariants (the audit will check these)
- **Global (poolless) rows are byte-identical**, including the route_snapshot
  canonical digest. A new field enters the digest ONLY when `pool_id != ""`
  (the exact conditional-field precedent already used for the
  `*_model_hash_algorithm` fields in RouteSnapshot.Value()).
- **Digest round-trip integrity.** DECISION GATE (from the flow map): if the
  route_snapshot digest is ever recomputed from the stored row, then `pool_id`
  MUST be persisted as its own column AND read back into the reconstructed
  RouteSnapshot before any re-derivation, or the digest binding is unsafe and
  must be dropped in favor of a plain non-canonical label column. Confirm the
  recompute-on-read answer before binding into Value().
- **Additive migration only** — nullable columns via the existing
  ensureColumns/ALTER pattern; the immutable-row trigger must still hold.
- No change to billing arithmetic, settlement mode, or payout.

## Test matrix (write FIRST)
| # | Test | Assertion |
|---|---|---|
| E1 | RouteSnapshot.Value()/Digest() with PoolID=="" | byte-identical to pre-change (golden digest regression) |
| E2 | RouteSnapshot.Value() with PoolID="P" | canonical value/digest includes pool_id |
| E3 | InsertRouteSnapshot + read-back with PoolID="P" | pool_id persisted and round-trips; digest re-derivation (if any) matches |
| E4 | requestlog Insert with PoolID="P" then read | pool_id column persisted |
| E5 | requestlog Insert with PoolID="" (global) | pool_id NULL; row otherwise unchanged |
| E6 | buyer hot path: pool request | state.poolID flows into both records |

## Deferred-decision note
`pool_id` mismatch-rejection at settlement (SPEC-042 R006 "reject the entry
before payout accounting on mismatch") is only meaningful once payouts execute;
for v0.1 labels-only it is recorded and, if bound into the digest, tamper-evident.
