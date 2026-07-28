# A4 — In-band signed catalog provenance

**Type**: ship-now · **Size**: S · **Dependencies**: none (shares SPEC-023 with A2/A8)

## Problem (roadmap §4.3, F3)
`bench_gate.provenance` ships as a **hardcoded client-side backfill table**
(`AutotuneRecommend.swift:757-840`), not signed catalog bytes — the Ed25519
signature covers zero provenance bytes, and the coordinator accepts nil and
substitutes nothing (`autotune_feeds.go:500-507`). `require_provenance` is
enforced only in `generate`, not at the other four `validate_candidate` call
sites (`catalog-release.py:1324, 1589, 1649, 1697, 1721`).

## Change
Next catalog release carries `bench_gate.provenance` **in-band**; add
`require_provenance` at every `validate_candidate` call site; adopt the §7
provenance ladder (including `omlx_seeded`), retiring the client backfill and
coordinator nil-acceptance with that release.

## Files
`scripts/catalog-release.py`, catalog JSONs, `AutotuneStrictJSON.swift` /
`AutotuneRecommend.swift`, `internal/buyer/autotune_feeds.go`, SPEC-023 amendment.

## Non-goals
Does **not** change any gate's advisory status and does **not** re-derive any
gate value (that is Brief B7, unbuildable at current fleet size). Provenance
stays metadata about an advisory field.

## Coordination
Shares the LOCKED `SPEC-023` with A2 and A8 — coordinate the edits.
