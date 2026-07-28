# B2 — Ceiling enforcement (routing exclusion)

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: its own SPEC. Does **not** gate on G0 (a static `min_ram_gb ≤ ceiling` check needs no traffic).

## Problem
A5 detects a ceiling-drift switch but does not stop it. FR-HG7's enforcement half.

## Shape the SPEC must take
Turn A5's alert into action: over-ceiling/uncatalogued → routing-ineligible for
that model; add evidence-TTL to the 30s `trust_revalidation.go` sweep. **Must
resolve the sole-provider case honestly**: integrity violations fail **closed**
even when that empties the pool — the `CanaryTripFloorHeld` floor
(`pool/provider.go:1254-1277`) stays scoped to canary/health uncertainty, never
to capacity/catalog/hash violations. A held floor must degrade to the smallest
admitted model, never no-op, and must key on the **admitted** model identity,
not the self-reported `ModelID`. Also: warm-up probe-target behavior when the
ceiling changes (`providerProbeModelID` is the live consumer). Flips SPEC-032
AC-F1/AC-F2 to pass.
