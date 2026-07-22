# RESEARCH_236 P4 — ARCHITECT audit lane (network-harness cache-reuse gate)

You are an **architecture / design auditor**. Review ONLY the diff of
branch `research/236-p4-cache-regression` against `origin/main` (commit
`b8fd549a`). The diff adds a phase-C benchmark regression gate (B8/B9) to
the network-harness to guard the ~64% sticky KV-cache reuse win (#376).
Files listed in the CODE-lane prompt in this directory.

## Design questions to judge

1. **Does the instrument actually measure what it claims?** The gate infers
   reuse from a single-shot request model (no conversation-history
   reconstruction): consecutive sticky-routed requests share an identical
   large prefix, so a warm turn's `cached_prompt_tokens` reflects the
   provider's prefix-cache hit. Is that a sound way to exercise prefix-cache
   reuse (vs probe.mjs's multi-message approach)? Any way it silently
   measures 0 even when reuse IS working (e.g. prefix below cache
   granularity, cross-buyer cache pollution, provider eviction)?
2. **Threshold design.** B8 floor 0.40 (vs measured 0.64) and B9 ratio 0.90
   are PROVISIONAL — the 2026-07-22 prod baseline found 0 reuse on the
   current pool, so a working floor could not be transcribed. Is shipping
   provisional thresholds (clearly labelled) with a documented
   calibration-pending note the right call, or should the gate ship
   SKIP-only until a reuse-capable provider is present? Is FAIL-on-0
   (present-but-zero) the correct semantics, or should sustained-0 be a
   WARN to avoid a permanently-red gate on a pool that never supported
   reuse?
3. **SKIP vs FAIL taxonomy.** Is the SKIP (usage absent / no cached turns)
   vs FAIL (present-but-collapsed) split coherent with how B5/B6/B7 already
   SKIP, and does it avoid both false-green and false-red?
4. **Fit with the corpus.** Does `sticky_cache` compose cleanly with the
   existing pattern set (interval/cold_warm_pairs) and the B-invariant
   framework? Is the single-buyer, 4000-context-cap scenario a durable gate
   given pool/model drift (the committed model may leave the pool)? Should
   the model be pinned differently?
5. **Wiring as a continuous gate** — is the design amenable to a
   scheduled/CI phase-C run, and are the artifacts (benchmark_summary
   cache_reuse block) sufficient for trend tracking?
6. **Anything over-engineered or missing** for the stated goal (a loud
   guard on the reuse win).

## Rules

- FINDINGS ONLY: CRITICAL / HIGH / MEDIUM / LOW / INFO with location and a
  concrete recommendation. Bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
- Judge the design of the diff; do not rewrite scope. Note explicitly if a
  concern is a pre-existing harness limitation rather than introduced here.
