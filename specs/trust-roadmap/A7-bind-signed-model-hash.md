# A7 — Bind the already-signed model hash

**Type**: ship-now · **Size**: S (~3-5 operator hours) · **Dependencies**: none

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

## Problem (roadmap §4, tier2 audit)
The SE attestation already signs `claimed.model_hash` and the coordinator
discards it — `pillar_c.go` references `Claimed` only to hash it into an audit
digest (`pillar_c.go:433,437,449,460`), never comparing it to the catalog.

## Change
Compare the SE-signed `claimed.model_hash` against the catalog row in
`pillar_c.go`. **On mismatch, emit an attestation-mismatch alert (observe/WARN),
not a route-exclusion** — the SE path is `require_attestation: false` and
non-load-bearing, so this is a signal, not a gate, until attestation is
enforced. Genuinely free — the value is already on the wire, already signed, and
the comparison is local; **no wire or schema contract changes.**

## Files
`internal/tier2/pillar_c.go`; test in `internal/tier2/`.

## Non-goals
Does **not** re-derive the hash from loaded tensors (needs SPEC-036). Does
**not** touch `weights_manifest_sha256` (decide separately — it may need a
catalog schema field, which would make it a contract change). **Rate-card
signing is Brief B10**, not here — signing `/v1/rate-card` is a SPEC-023
wire-contract change with an undecided mechanism.
