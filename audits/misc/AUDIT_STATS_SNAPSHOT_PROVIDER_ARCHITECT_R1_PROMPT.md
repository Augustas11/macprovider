# SPEC-017 SnapshotProvider wiring — ARCHITECT-lane audit (R1)

You are the **architect** lane of a three-lane audit (code /
security / architect) of the pool.Registry → stats/rollup
SnapshotProvider wiring. Stay narrowly in your lane — code
correctness goes to code lane; disclosure goes to security.

## Branch / commit
- Branch: `feat/stats-snapshot-provider`
- Worktree root: `/Users/augstar/macprovider-stats-snapshot`
- Base: `origin/main` @ `66f372e`
- Files in scope:
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot.go` (NEW)
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot_test.go` (NEW)
  - `phase4-coordinator/cmd/coordinator/main.go` (1-line wiring)

## What this change does (operator summary — NOT the audit answer)

Wires 5 of the 9 §5.1.1 live-snapshot fields to real
`pool.Registry` state via a new `poolsnapshot` adapter package.
The remaining 4 hardware-inventory fields (bandwidth, power, GPU
cores, CPU cores) stay at zero — flagged as follow-up because
`pool.Provider` doesn't carry chip identity today (SPEC-026
onboarding does; a join is needed).

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Package placement

- `phase4-coordinator/internal/stats/poolsnapshot/` sits under
  `stats/` but imports both `stats/rollup` (for the interface) and
  `pool` (for the type). The rollup package itself does NOT import
  pool — its interface is defined narrowly to avoid that coupling.
  poolsnapshot is the composition-root adapter.
- Alternative placements to consider:
  - `cmd/coordinator/poolsnapshot.go` — pure composition-root,
    but pollutes main package with logic that deserves unit
    tests.
  - `internal/pool/statssnapshot.go` — inverts the coupling
    direction; pool would import rollup, which is worse.
  - `internal/stats/snapshot/` (drop "pool" from the name) —
    naming would suggest it's a general adapter surface, but
    it's specifically pool-derived. Current name is more honest.
  Argue whether `internal/stats/poolsnapshot/` is right.

### ARCH-2. Interface boundary (`Source`)

The adapter defines a local `Source` interface:
```go
type Source interface {
    Snapshot() []pool.Provider
}
```
- This is method-superset-compatible with `*pool.Registry`
  (Registry has more methods; only `Snapshot()` is needed here).
- Alternative: import the concrete `*pool.Registry` — simpler but
  couples the adapter to Registry's full surface. Current design
  is testable in isolation (poolsnapshot_test.go uses
  `fakeSrc []pool.Provider`).
- Tradeoff: the interface method returns `[]pool.Provider` — a
  concrete-type coupling. To fully decouple we'd need a
  poolsnapshot-local `ProviderView` struct with only the fields
  we read. Overkill for v1? Argue.

### ARCH-3. Missing fields (bandwidth, power, cores) — deferral design

Four fields intentionally left at zero:
`BandwidthGBPerSec`, `NetworkPowerKW`, `GPUCoresTotal`,
`CPUCoresTotal`.

- The wire format on `/v1/stats/overview` still emits these keys
  with value 0. Consumers cannot distinguish "no data" from
  "genuinely zero". This is CONSISTENT with the SPEC-017 v0.1.8
  wire contract, but it's a semantic gap.
- Options:
  1. Ship as-is (0 = unknown, documented in OPS.md + PR body).
  2. Add a companion field (`snapshot_completeness`) enumerating
     which fields are live vs unwired. SPEC change.
  3. Wire the fields via a SPEC-026-onboarding join — chip
     identity → per-chip TDP/cores/bandwidth lookup table.
     Non-trivial: pool.Provider doesn't have chip; onboarding is
     a separate PG table; the join happens on `provider_id`.
- The current PR takes option 1. Argue whether option 2's
  operator-observability benefit outweighs the spec-change cost.
  Argue whether option 3's data-completeness benefit is worth
  bundling into this PR vs a follow-up.

### ARCH-4. Rollup tick coupling

The adapter is called from `stats/rollup.runOverviewTick` once per
tick (default interval per `rollup.Config`). Each call takes
`Registry.mu.RLock()` inside `Snapshot()`.

- Overview tick interval vs registry mutation rate — if the tick
  is much slower than provider connect/disconnect, the snapshot
  is always slightly stale by design (a normal telemetry
  tradeoff). Confirm this is documented.
- Is there any risk of the tick running while the coordinator is
  in an inconsistent state (e.g. mid-startup before providers
  connect)? Trace startup ordering: registry is created line
  127; rollup started line ~326. There's no explicit "wait for
  first heartbeat" — rollup can fire before any provider is
  registered. The output during that window is zeros, which
  matches the pre-PR behavior. Fine.

### ARCH-5. Testability posture

- Adapter has 10 unit tests using a `fakeSrc` slice-typed fake.
- No integration test that runs the full rollup with a real
  Registry attached — `rollup_integration_test.go` uses
  `ZeroSnapshotProvider` throughout (24 test sites). Should any
  of those switch to `poolsnapshot.New` with a fake registry, or
  is unit coverage sufficient?
- The main.go wiring itself has no test. It's a 1-line
  composition; the individual pieces are covered. Judge
  sufficient?

### ARCH-6. Backward compatibility with SPEC-017 wire contract

- All 5 newly-live fields have EXISTING wire types (int / int64 /
  float64) matching SPEC §5.1.
- Prior operators / partners scraping the endpoint saw zeros.
  Now they'll see non-zeros. If any consumer was pinning "== 0"
  as a health check (e.g. "network is empty"), that consumer
  breaks. Realistic threat? External partners could be running
  scrapers; malibu.tech will be the FIRST major consumer per
  the initiating request. Argue whether a version-bump signal
  is needed (SPEC-017 v0.1.9 with a changelog line "live
  overview snapshot now populated").

### ARCH-7. Naming / vocabulary

- `poolsnapshot` package name vs `snapshot.go` file name inside.
  The internal file is just `poolsnapshot.go` — clean.
- The exported struct is `Provider` (not `SnapshotProvider`)
  because the package name already carries the "snapshot"
  qualifier. `poolsnapshot.Provider` reads well at the call
  site. Argue.
- `onlineForStats` is a private helper — the name says "for
  stats" but that's a tautology (this whole package is for
  stats). Better name? `serving`? `liveForCounts`?

### ARCH-8. Future extensibility

If we add option-3 (SPEC-026 chip join) later, the adapter would
need a new dependency (onboarding PG store). The current `Source`
interface would extend to something like `PoolSource` +
`OnboardingSource`. Argue whether the current `New(src Source)`
signature blocks that evolution or accommodates it via a new
`NewWithOnboarding(...)` constructor.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence architectural change>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/STATS_SNAPSHOT_PROVIDER_R1_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE`
