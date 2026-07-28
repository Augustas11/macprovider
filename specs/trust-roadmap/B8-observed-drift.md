# B8 — Observed data into drift detection

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: G0 + B1.

## Problem / shape
Today's drift check compares the provider's heartbeat TPS claim against the
provider's own earlier benchmark claim — self-report vs self-report, WARN-only
(`internal/pow/drift.go`). Feed B1/B3 aggregates in as the drift baseline;
replace the provider-supplied `ModelLoadTimeMs` Pillar D threshold
(`pillar_d.go:167-197` — the provider sets its own anomaly threshold) with
observed history; add the RAM-self-report vs verified-tuple tripwire.
