# B1 — Persist per-request TTFT/decode columns

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: a SPEC-002 amendment (nearly ship-now otherwise).

## Problem
True TTFT/decode are measured on every request and discarded (roadmap §4.7).
`request_log` has no column for them.

## Shape the SPEC must take
Nullable `ttft_ms`/`decode_ms` on `request_log`, populated from
`requestPhaseTiming` across all 8 relay paths. **Columns only — no classifier,
no aggregate** (those are B3). It is a **governed schema change**: SPEC-002 owns
the table (`SPEC-002:1666-1690`) and SPEC-005 declares it read-only
(`SPEC-005:526-534`), so it needs a SPEC-002 amendment + migration + consumer
notes for SPEC-005/SPEC-007. Promote to a ship-now piece once the amendment is
drafted. Value strictly increases with earlier start — draft the amendment early
so columns accumulate in parallel with G0.
