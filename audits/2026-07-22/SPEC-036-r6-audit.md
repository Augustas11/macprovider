# SPEC-036 — Round-6 SPEC audit (5 lanes) + fixes

**Date:** 2026-07-22
**Reviewed revision:** `0b90999c` (post round-5)

## Round-6 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code | 0 | 2 | 4 | 0 |
| codex security | 0 | 1 | 0 | 0 |
| codex architect | 0 | 3 | 2 | 0 |
| claude adversarial | 0 | 0 | 0 | 0 → **ACCEPT** |
| claude product-design | 0 | 0 | 1 | 1 |

**The Claude adversarial money-path lane reached 0/0/0/0 and returned ACCEPT** ("clears
the bar for LOCK"; could construct no state/timing/churn/replay/reference/breaker
sequence settling a covered enforce row payable when it must not). Product at 0H/1M.
The codex HIGHs concentrated on (a) the `warn_only`-alias of the downgrade/rollback
path vs the quarantine carve-out (dominant; also product-M1 and architect-H1/security-H),
(b) `hardware_runtime_class` not threaded through the immutable evidence chain, and
(c) all-profile windows authorizing unprobed profiles.

## Fixes (all C/H/M addressed)

- **warn_only vs preserved adverse state (product-M1, architect-H1, security-H):** the
  warn-only definition now carries a Preserved-adverse-state exception — active
  `quarantined_compute_drift`/`blocked:<reason>` overlays and active circuit-breaker
  holds established under enforce survive EVERY enforce→warn_only transition (FR-16
  manual rollback and FR-1 auto-downgrade) and continue rejecting billable covered
  buyer routing/settlement until the FR-10 clear or FR-16 `cleared`; only clean keys
  get warn-only's no-effect fallback. FR-16 rollback text aligned.
- **hardware_runtime_class threading (codex code-H1, architect-H3):** bound into the
  reference-event payload, `reference_set_admissibility_v1` key, FR-1 activation
  exact-match list (with cross-artifact equality + fail-closed on mismatch), the probe
  request payload, and the Migration §6 calibration key.
- **Abusive-inconclusive classification (codex code-H2):** FR-1/FR-10 now count
  FR-9-classified abusive-inconclusive events, not raw inconclusive results.
- **All-profile unprobed authorization (architect-H2):** all-profile windows are a
  closed profile grid — every covered profile must independently satisfy
  sample/pass/freshness/calibration/reference before the aggregate is payable; the
  covered-profile-set digest is bound into the window and request-start capture.
- **Unbounded multi-arm support (codex code-M):** `max_active_references` policy field
  (default 2, cap 4) bounds `N` and the `(N+1)K` support.
- **Threshold record not closed (codex code-M):** FR-8 record declared closed over the
  full 8-tuple key + fields, matching the FR-13 digest preimage.

## Convergence assessment

Adversarial money-path lane ACCEPTED at 0/0/0. Product converged to a single labeling
MEDIUM, now fixed. The codex findings were schema-threading completeness and
consequences of recent additions, all bounded and applied. Round-7 is the final check.
