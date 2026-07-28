# A5 — Ceiling-drift detection (observe-mode)

**Type**: ship-now · **Size**: M (~12-18 operator hours) · **Dependencies**: none (two contract touches below)

## Problem (roadmap §4.5, SPEC-032 FR-HG7 — silent half)
A heartbeat model switch is applied unconditionally (`pool/provider.go:1851`)
and emits no `SwapEvent` when it skips the loading transition (`:1899-1916`).
The live hash chain (`require_hash_verified`) is re-checked per heartbeat, so a
switch to an *uncatalogued* model is caught — but a switch to a *catalogued
larger* model (a capacity-ceiling drift) is applied silently and unseen.

## Critical scope point (do not build the naive version)
The admitted ceiling is only computed **when the hello gate is on**:
`checkAutotuneHelloGate` returns before `EvaluateHelloGate` when
`RequireAutotuneHelloGate` is false (`server.go:2333`), and the evidence store
is wired only under that flag (`cmd/coordinator/main.go:583-590`). The gate is
**off in prod**. A naive A5 that persists the value the gate computed would be a
**no-op in the live config**. A5 must compute the ceiling in **observe mode,
independent of the flag**: wire the evidence lookup unconditionally (read-only
observe variant), derive the cap via `ResolveMaxAdmission(LatestVerified(...))`
(`internal/autotune/gate.go:18-58`), and alert on drift. This is buildable
because the inputs exist regardless of the gate — evidence submission is
default-on and the `stats-hardware-verifier` worker produces `verified` rows on
its own timer. Where a provider has **no** verified evidence, A5 still alerts on
any switch to an uncatalogued/unresolved model — loud, not silent.

## Change
Persist `MaxAdmittedMinRAMGB` on `pool.Provider` (does not exist today — only
`MaxAdmittedModelKey:200`/`MaxAdmittedModelID:201`; `HelloGateDecision` computes
the RAM value then drops it, `gate.go:13`), populated from the observe-mode
lookup. On `modelIDChanged`, compare **in memory** and emit a provider event +
operator alert. **Detection only — no routing exclusion, no eviction.**

## Contract touch 1 — SPEC-035
The new alert kind extends the provider-event taxonomy, a **closed set owned by
SPEC-035** (`internal/providerevents/taxonomy.go:30`, enforced `store.go:577`;
authority `specs/AUTHORITY.json:473`, conformance `CONFORMANCE.json:1518`).
Needs a SPEC-035 amendment + conformance update, **or** route the alert outside
the closed taxonomy (operator monitor only).

## Contract touch 2 — observe-mode wiring
Unconditional evidence-store construction touches `cmd/coordinator/main.go`
startup. Not a spec change — enforcement stays flag-gated; only observation
becomes always-on.

## Plumbing note
`min_ram_gb` for the new model needs the `autotune.Catalog` on `ws.Server`
(`s.autotuneCatalog`, `server.go:912`), not the pool. Resolve on the `ws` side
and pass the resolved integer into the pool — do not read Postgres under
`Registry.mu`.

## Files
`internal/pool/provider.go`, `internal/ws/server.go`, `cmd/coordinator/main.go`,
`internal/providerevents/taxonomy.go` + `store.go`, `specs/SPEC-035` +
`CONFORMANCE.json` (or the monitor-only alternative).

## Non-goals
Emits an alert; changes **no** routing decision. Enforcement is Brief B2. A5
*surfaces* the hazard (ends the silence); it does not stop the serving.

## Note
Because A5 carries a SPEC-035 amendment (one audit loop for the spec, one for
the IMPL) it is larger than the other A-pieces; it is in the committed minimum
because it is the genuine hazard closure, not because it is the cheapest.
