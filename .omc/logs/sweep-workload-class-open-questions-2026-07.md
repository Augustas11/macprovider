# Sweep Workload-Class Open Questions

**Date:** 2026-07-09
**Scope:** Maintainer decisions needed before implementing SPEC-029.

1. Should the static catalog field be named `workload_profiles`, `per_class`, or another canonical term?

   Recommendation: use `workload_profiles` because v0.1 keys are beta harness workload names, not a general request taxonomy.

2. What traffic-weighting policy should choose a single legacy/default winner if consumers cannot yet use per-workload profiles?

   Recommendation: use observed buyer traffic mix from `runs.sqlite` when available, and require an explicit report note when falling back to equal weights.

3. What numeric TTFT gates should apply to `long_context` and `streaming_check`?

   Recommendation: keep short/medium/code/agent gates strict, define a separate long-context prefill/TTFT gate, and treat streaming TTFT as a probe gate rather than a winner axis.

4. Should SPEC-028 speculative acceptance rate be a hard winner gate or an advisory metric in v0.1?

   Recommendation: record acceptance rate per workload and target/draft pair first; promote to a hard gate only after enough local sweep data exists.

5. Which follow-up SPEC owns runtime workload classification and class-routed serving?

   Recommendation: create a separate coordinator/provider routing SPEC. SPEC-029 should stop at per-workload winners as signed recommendation data.
