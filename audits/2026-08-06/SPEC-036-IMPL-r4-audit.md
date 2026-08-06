# SPEC-036 IMPL — Round-4 BUILD audit (3 codex lanes) + fixes

**Date:** 2026-08-06

## Round-4 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code-correctness | 0 | 4 | 2 | 2 |
| codex security / money-path | 0 | 1 | 1 | 1 |
| codex architecture / spec-fidelity | 0 | ~2 | 2 | 1 |

Third round at 0 CRITICAL. The round-4 findings are almost entirely NEW, non-overlapping
areas (canary ordering, duplicate digests, K-retry field binding, wire-shape fidelity of
settlement-bearing digest preimages) — genuine design-discovery on a large abstraction,
not re-litigation of prior rounds.

## Fixes (all C/H/M addressed)

1. **Latest-window logic used insertion order, not event time** (code-H1): `eligible`
   now sorts canaries by `atMs` (stable tie-break) before all latest/window/TTL/warn
   checks; a delayed older canary can no longer verify over newer quarantine candidates.
2. **Telemetry-origin accumulator could pin a later enforce quarantine dormant** (code-H2):
   a quarantine established under enforce+SPEC-022-enforce now UPGRADES any prior
   telemetry-only origin (fresh enforce re-adjudication, FR-3).
3. **Duplicate reference digests satisfied captured quorum** (sec-H1): the payable path
   now requires ≥ `ReferenceQuorumCount` DISTINCT non-empty reference event digests.
4. **K=256 retry only presence-checked** (code-H4): added `ValidateRetryBinding` — a
   retry must bind the exact K=64 covered key, positions (prompt/prefix/context), and
   reference digests, and echo the K=64 probe_id.
5. **Reference freshness accepted future/missing timestamps** (sec-M1): require
   `NowUnixMS > 0`, `RefreshedAtUnixMS > 0`, and `RefreshedAtUnixMS <= NowUnixMS`.
6. **Flapping `clear_pass_count_sequence` was unreachable** (code-M1): the overlay marks
   a flapping-origin manual-review block pass-sequence-clearable; `AttemptClear` honors it.
7. **Underspecified policy / missing digest fields** (code-M2, arch-M2): `ActivationCheck`
   now requires `normalization_basis == full_distribution` and nonzero `enabled_at`;
   `Policy.Digest` binds `enabled_at`; `ThresholdRecord` gained the closed `coverage`
   object (validated against the covered key) and requires RFC3339 calibration windows.
8. **Probe result missing `validation_metadata`** (arch-M1): added the closed
   `ValidationMetadata` block + `ValidateResultVariant` enforcing the FR-6 discriminated
   union (measurement carries positions+metadata; provider_inconclusive carries neither).
9. **`reference_set_admissibility_v1` not a closed struct** (arch-H1): added the closed
   struct + `BuildReferenceSetAdmissibility` + `Digest` (order-independent), the
   provable preimage for the capture/auditor admissibility digest.
10. **Reference distribution not validated before fault** (code-M3): mass>1 / invalid
    probability reference distributions are `schema_invalid`, never clamped to TV 0.
11. **Zero false-positive budget wrongly rejected / empty route digest** (code-L): budget
    range is `[0,1]`; a missing hardware-class digest is now unreadable (higher precedence).

## Carried LOW (documented)

- **quarantine-candidate counter unpruned** (both lanes): over-blocks, never mis-pays;
  enforce unreachable in v0.1. Rolling-window prune is the follow-up.
- **All-profile grid ResolveState integration** (code-H3): the MONEY gate already enforces
  coverage — settlement fails closed via the captured `RequestSamplingProfileCovered`
  boolean (computed by `RequestProfileCovered`/`AllProfileGridSatisfied`), proven by
  AC-11. Integrating the grid into the routing-time `ResolveState` (a non-money helper)
  is a scoped follow-up for the live settlement-wiring PR; it does not affect settlement
  safety in this default-off slice.

## Post-fix state

`go build ./...`, `go vet`, `golangci-lint` green; all 17 AC fixtures pass. Round-5
verification recorded separately; round 5 is the bounded decision point.
