# SPEC-017 SnapshotProvider wiring — CODE-lane audit (R1)

You are the **code** lane of a three-lane audit (code / security /
architect) of the pool.Registry → stats/rollup SnapshotProvider
wiring. Stay narrowly in your lane.

## Branch / commit
- Branch: `feat/stats-snapshot-provider`
- Worktree root: `/Users/augstar/macprovider-stats-snapshot`
- Base: `origin/main` @ `66f372e`
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot.go` (NEW)
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot_test.go` (NEW, 10 tests)
  - `phase4-coordinator/cmd/coordinator/main.go` — replaces
    `statsrollup.ZeroSnapshotProvider{}` with `poolsnapshot.New(registry)`
    at line ~321; adds import; updates the surrounding comment block
    (lines ~262-268).

## What this change does (operator summary — NOT the audit answer)

Before: SPEC-017 `/v1/stats/overview` returned zero for every §5.1.1
live-snapshot field (nodes_online, nodes_hardware_attested,
network_utilization_pct, unified_ram_gb_total, models_serving,
bandwidth_gb_per_s, network_power_kw, gpu_cores_total,
cpu_cores_total) because the default `ZeroSnapshotProvider` was
installed and no real snapshot source was wired.

This branch adds a `poolsnapshot` adapter that reads
`pool.Registry.Snapshot()` on each rollup tick and derives the five
directly-derivable fields (`NodesOnline`, `NodesHardwareAttested`,
`UnifiedRAMGBTotal`, `ModelsServing`, `NetworkUtilizationPct`). The
four hardware-inventory fields (`BandwidthGBPerSec`,
`NetworkPowerKW`, `GPUCoresTotal`, `CPUCoresTotal`) stay at zero
because `pool.Provider` doesn't carry chip identity — that's a
follow-up joining against SPEC-026 onboarding.

## Code-lane scope (apply each; stay in lane)

### CODE-1. `OverviewSnapshot` correctness

Walk each field derivation against `pool.Provider` semantics:

- `NodesOnline` counts providers where `onlineForStats(p)` is true.
  `onlineForStats` filters: `AuthState != AuthBearerlessDuplicate`,
  `len(PendingReceiptPubkey) == 0`, `State in {StateReady,
  StateBusy}`. Trace:
  - Is `StateBusy` the right inclusion? A busy provider is serving
    a request but not accepting new ones. For a network-wide
    "nodes online" count, this SHOULD include busy providers.
    Confirm.
  - Does `StateDegraded` / `StateDraining` / `StateUnavailable`
    belong online? Current code says NO. Confirm — degraded is
    still on the wire but not routable; draining is
    winding-down; unavailable is dead.
  - Providers with `PendingReceiptPubkey` are mid-key-rotation and
    non-routable (SPEC-015). Excluding them from "online" — is
    that consistent with what an operator would expect a public
    stat to show? Alternative view: they ARE connected and
    hearbeating; the exclusion may over-shrink `NodesOnline`
    during a rotation window.
- `NodesHardwareAttested` — subset of NodesOnline with
  `AttestationStatus == AttestationStatusAttested`. Note the four
  other attestation states (`Failed`, `Stale`, `NotRequired`,
  `Unsupported`, and empty zero-value) are NOT counted. Is the
  strict "attested" match correct, or should `NotRequired` count as
  "hardware trust satisfied"?
- `UnifiedRAMGBTotal` — sum of `RAMGB` across online providers.
  `RAMGB` is `int`; overflow risk on int32 platforms at 2M GB.
  We're targeting int64-underneath but the field is `int`.
  Documented anywhere?
- `ModelsServing` — distinct `ModelID` across online providers.
  Empty `ModelID` excluded (a provider mid-load with no model
  yet). Correct.
- `NetworkUtilizationPct` — `(SlotsTotal - SlotsFree) / SlotsTotal
  * 100` aggregated across online providers only. Guards:
  `slotsTotal > 0`, `used < 0 → 0`, cap at 100. Trace overflow:
  `int64(used) * 100` — if `used > 2^56` it overflows. Realistic?
  No — real total slots stays in thousands. Still, note.

### CODE-2. `Source` interface + `New` constructor

- `Source` interface exposes only `Snapshot() []pool.Provider`. Is
  this the minimal surface — or should the adapter also depend on
  `pool.Registry.Count()` for a cheaper "no providers online"
  early exit? (Snapshot allocates a fresh slice every tick.)
- `New(nil)` panics. `poolsnapshot_test.go:TestNilSourcePanics`
  pins the panic. Is panic the right posture, or should
  `New` return an error?
- `p.now` field is a function var overridable in tests only via
  package-internal access (test sets `p.now = fixedTime`). No
  public `WithClock` option. Is that a smell for production
  observability (e.g. wanting to freeze `At` in a replay-tool)?
  Probably fine for v1 but flag.

### CODE-3. Concurrency + performance

- `OverviewSnapshot` is called from
  `stats/rollup.runOverviewTick` on a fixed interval (default per
  `rollup.Config`). Each call does `p.src.Snapshot()` which under
  the hood takes `Registry.mu.RLock()` and allocates
  `[]Provider` with a full copy of the map. At current provider
  scale (hundreds → low thousands) this is fine. What's the cost
  if the registry grows to 10k? Alternative: streaming visitor
  (`Registry.Range(func(p Provider) bool)`) — not present today.
  Flag as scale-follow-up only.
- Read-only from the caller's perspective, so no lock leak.
  Confirm no field is written back.

### CODE-4. Test adequacy

Existing 10 tests:
- `TestEmptyRegistryReturnsZeroSnapshot` — asserts all 9 fields
  are zero + `At` matches fixed time.
- `TestCountsReadyAndBusyAsOnline` — 5 providers across all 5
  states, asserts 2 online (ready+busy).
- `TestExcludesBearerlessDuplicate`.
- `TestExcludesPendingReceiptPubkey`.
- `TestHardwareAttestedSubset` — mixed attestation statuses.
- `TestUtilizationFromSlots` — mixed slot use across 3 providers.
- `TestUtilizationIgnoresOfflineProviders`.
- `TestUtilizationClampsAtHundred` — pathological SlotsFree >
  SlotsTotal.
- `TestModelsServingDistinct` — dedup + empty-string skip.
- `TestNilSourcePanics`.

Missing coverage to flag?
- Attestation with `NotRequired` status — see CODE-1 open question.
- A provider whose state is Ready but has `SlotsTotal == 0`
  (mid-load, no capacity reported yet) — should it count as
  online? Current code says yes (utilization contribution is
  skipped because we guard `SlotsTotal > 0`, but the online
  count still increments). Confirm this is right.
- A single provider transitioning bearer states — but that's a
  Registry-layer concern, not adapter.

### CODE-5. main.go wiring

- Line ~321 (`statsRollup, err = statsrollup.New(...,
  poolsnapshot.New(registry), ...)`). The `registry` variable is
  the one from line 127 (`pool.NewRegistry(cfg.Providers)`).
  Confirm no earlier `registry` shadow.
- Import at line ~29
  (`"github.com/augstar/macprovider-coordinator/internal/stats/poolsnapshot"`
  added between `statsmetrics` and `statsrollup`). Alphabetical
  order preserved?
- The comment block above (lines ~262-268) was rewritten. Verify
  the new wording ("Fields that need per-chip hardware profiles
  ... stay at zero until a chip-identity join with SPEC-026
  onboarding lands") is accurate.

### CODE-6. Comment quality
- `poolsnapshot.go` doc comment explains scope + follow-up.
- `Provider.OverviewSnapshot` doc comment is one-line — sufficient?
- `onlineForStats` has a comment; `Source` has a comment. Adequate?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/STATS_SNAPSHOT_PROVIDER_R1_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
