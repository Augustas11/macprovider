# SPEC-023 Addendum (DRAFT) — oMLX-seeded provisional gates

**Status:** DRAFT / proposal. NOT normative yet. Destined for a SPEC-023 §12
(and small §3.2 / §5 amendments) after the codex SPEC-audit loop returns
0 CRITICAL / 0 MAJOR / 0 MINOR. Until then this file is a design contract, not
a shipped requirement. Non-money-path; does not alter any current gate value.

**Origin:** RESEARCH_231 (oMLX board calibration) + DECISION_CRITERIA Entry 179.
Motivated by the hardware bottleneck: macprovider's sole bench executor is an
M5 32 GB Tier-C Air, so new catalog rows for models/hardware it cannot self-bench
(anything needing >32 GB, e.g. FB-02/03/04) stall indefinitely. This addendum lets
a new row be *seeded* from the oMLX community board as a **provisional** gate, then
*converged* by verified provider measurement — without ever letting unverified
community data become a paid-default admission decision.

## 1. Core invariant (the line that keeps the trust model intact)

oMLX board data is **community self-reported and unattested**. It MAY inform the
*starting* gate of a non-default row. It MUST NEVER:
- set or hold the `bench_gate` of a `recommendable` row,
- **raise** an existing gate whose provenance is `verified_local`,
- **hard-block** a provider (SPEC-023 §5 gates stay advisory; no `hard_min_sustained_tps` is introduced here),
- serve as the sole evidence to promote any row to `recommendable`.

macprovider's verification stack (proof-of-weights SPEC-032, hardware-evidence
verifier SPEC-033, OPoI drift, canary probes) remains the only admission authority.
oMLX is a **prior**; a verified provider autotune run is the **posterior** that
overwrites it.

## 2. Schema additions (SPEC-023 §3.2 candidate/admission catalog)

Add to each catalog row a `bench_gate.provenance` discriminator and, when seeded,
a `bench_gate.gate_seed` object:

```json
"bench_gate": {
  "min_sustained_tps": 18.0,
  "max_4k_ttft_ms": 3500,
  "provenance": "omlx_seeded",              // enum: verified_local | omlx_seeded | hand_set
  "gate_seed": {                             // REQUIRED iff provenance == omlx_seeded
    "omlx_snapshot_id": "omlx-benchmark-snapshot-2026-07.json",
    "board_release_tag": "v0.5.3",
    "board_p25_tg": 90.6,
    "engine_delta_applied": 0.85,
    "mtp_discounted": true,                  // true if board rows were MTP/spec-decode builds
    "cells_used_n": 12,                      // n>=K distinct rows, each <=120 days old
    "seeded_at": "2026-07-22T00:00:00Z"
  }
}
```

- `provenance` is REQUIRED on every row. Existing rows are `verified_local` or
  `hand_set`; the migration sets each accordingly (no value change).
- `gate_seed` is REQUIRED when and only when `provenance == "omlx_seeded"`; absent
  or malformed → the row is ineligible before download (same fail-closed posture as
  a missing `model_sha256` in §3.2).

## 3. Seeding rule (how a provisional gate is computed)

An `omlx_seeded` `min_sustained_tps` MUST be derived by the RESEARCH_231 floor
formula and constraints (Entry 179), NOT copied from the board:

```
min_sustained_tps = max(8, floor(board_p25_tg × engine_delta × 0.90))
```

- `engine_delta` per the current `UPSTREAM_WATCH.json` stanza, re-derived against the
  tracked oMLX stable release (NOT a `.dev` prerelease).
- **MTP / spec-decode discount (mandatory):** if the board rows are multi-token-prediction
  or speculative-decode builds, their TG includes acceleration macprovider's plain
  decode path does not have; `board_p25_tg` MUST be taken from non-accelerated rows,
  or explicitly discounted, and `mtp_discounted` set true.
- Cells: `n >= K` (K TBD in audit, e.g. 10) distinct rows on the same normalized
  chip+RAM bucket, each dated within 120 days and after the oMLX KV-memcpy fix
  (>= 2026-05-01).
- `max_4k_ttft_ms` MUST NOT be seeded/tightened from the board PP proxy (it
  underestimates macprovider cold-start TTFT 1.3–2.5×). An omlx_seeded row inherits
  a conservative default TTFT gate or leaves it unset (advisory-warn only).

## 4. Lifecycle — where a seeded gate is allowed to sit

An `omlx_seeded` row MAY be published only at `runtime_status ∈ {candidate, listed}`
— NEVER `recommendable`. It is therefore visible/benchable but is never a paid
default (SPEC-023 §4/§5 already require `recommendable` for defaults). Concretely:

- `candidate` — seeded gate, no macprovider verified run yet. Diagnostic/experimental.
- `listed` — seeded gate + >=1 verified provider autotune run recorded, but below the
  promotion threshold.
- **Promotion `listed → recommendable`** REQUIRES `>= N` (TBD, e.g. 3) verified
  provider autotune measurements on eligible hardware, each clearing the provisional
  gate, aggregated via the existing OPoI/attested-TPS telemetry. On promotion, the
  operator recomputes the gate from those verified measurements (the §4.3 local-median
  path) and flips `provenance` to `verified_local`. The oMLX seed is discarded, not
  retained, at promotion.

## 5. Transparency & staleness

- The `autotune --recommend` output (SPEC-023 §6) and `macprovider status` MUST
  surface `provenance` and, for seeded rows, a human-readable
  "gate is oMLX-seeded provisional (board vX, delta 0.85), not yet macprovider-verified"
  line, so a provider is never misled that a provisional QoS floor is a measured one.
- A `candidate` row still `omlx_seeded` after the refresh cadence lapses (e.g. 90 days
  with zero verified runs) reverts to `experimental` posture (or is dropped), so stale
  seeds do not accumulate as implied-verified.

## 6. Non-goals (unchanged from SPEC-023)

- Does not change §5 advisory-gate semantics or introduce a hard block.
- Does not let oMLX evidence produce a paid default or raise a verified gate.
- Not a runtime dependency on oMLX; the board is a build-time calibration input only.
- Does not resolve non-throughput blockers (residency/E1, VLM-pin/E3, rate-card):
  a seeded gate makes a row *provisionally publishable on throughput*; a row still
  fails admission on RAM/pin/rate-card independently (e.g. `qwen3.6-35b-a3b` stays
  blocked on E1/E3 + RESEARCH_227 regardless of its favorable board TG).

## 7. Acceptance criteria (sketch — to be finalized in audit)

- AC-OMLX-1: a row with `provenance=omlx_seeded` and `runtime_status=recommendable`
  is rejected by catalog validation (fail-closed).
- AC-OMLX-2: an `omlx_seeded` row missing `gate_seed` is ineligible before download.
- AC-OMLX-3: `autotune --recommend` never selects an `omlx_seeded` row as the default
  recommendation (inherits §5 `recommendable`-required gate).
- AC-OMLX-4: promotion to `recommendable` is refused unless `>= N` verified provider
  measurements clearing the gate exist; the promoted gate has `provenance=verified_local`
  and no `gate_seed`.
- AC-OMLX-5: seeded `min_sustained_tps` never below 8; never derived from a `.dev`
  board release; MTP rows discounted or excluded.
- AC-OMLX-6: `provenance` is surfaced in recommend output and `status`.

## 8. Implementation surfaces (informative — not part of the contract)

The normative contract is §1–§7. These are the code seams a BUILD_SPEC would touch,
listed so the implementation scope is legible:

| Stage | Surface | Change |
|---|---|---|
| Snapshot ingest | new operator tool `scripts/omlx_snapshot_seed.py` (or Go) | pulls the monthly `omlx-benchmark-snapshot-*.json` (browser-UA fetch; server-side 403s), applies §3 formula, emits provisional rows with `gate_seed` |
| Catalog schema | `phase3-binary/dist/static/autotune-candidates.json` + `phase3-binary/catalog/autotune/autotune-candidates.json` + baked `AutotuneCatalog.generated.swift` | add `provenance` (+ `gate_seed`); re-sign with `streamvc-autotune-static-v4/v5` |
| CLI consumer | `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` | decode `provenance`/`gate_seed`; surface in `--recommend` output + `status`; keep §5 advisory semantics (no new veto) |
| Catalog validation | catalog lint/sign path | enforce AC-OMLX-1/2/5 at authoring time |
| Promotion | operator step reading OPoI/attested-TPS aggregates (`internal/pow/*`) | count verified runs clearing the gate; recompute + flip `provenance=verified_local` |
| Coordinator | none | pool gates already advisory; no wire/routing change |
