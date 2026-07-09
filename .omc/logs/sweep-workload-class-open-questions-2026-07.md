# Sweep Workload-Class Open Questions

**Date:** 2026-07-09
**Scope:** Maintainer decisions needed before implementing SPEC-029.

1. What traffic-weighting policy should choose a single legacy/default winner if consumers cannot yet use per-workload profiles?

   Recommendation: use observed buyer traffic mix from `runs.sqlite` when available, and require an explicit report note when falling back to equal weights.

2. Which follow-up SPEC owns runtime workload classification and class-routed serving?

   Recommendation: create a separate coordinator/provider routing SPEC. SPEC-029 should stop at per-workload winners as signed recommendation data.

3. Should a later client SPEC consume `workload_profiles` directly in installer recommendation, or should it first remain a report-only/feed-only artifact?

   Recommendation: keep v0.1 report/feed-only for current clients, then add client consumption in a separate SPEC with explicit backward-compat tests.
