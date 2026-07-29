# B8 — Observed data into drift detection

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: not implemented. B1 is complete, but G0 is
broad-negative for current per-bucket authority; keep this deferred except for
a future narrow observe-only design over high-fill buckets.

**Gated on**: materially higher per-bucket demand or a narrow observe-only SPEC.

## Problem / shape
Today's drift check compares the provider's heartbeat TPS claim against the
provider's own earlier benchmark claim — self-report vs self-report, WARN-only
(`internal/pow/drift.go`). Feed B1/B3 aggregates in as the drift baseline;
replace the provider-supplied `ModelLoadTimeMs` Pillar D threshold
(`pillar_d.go:167-197` — the provider sets its own anomaly threshold) with
observed history; add the RAM-self-report vs verified-tuple tripwire.
