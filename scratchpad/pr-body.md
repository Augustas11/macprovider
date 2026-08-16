## P4 — multi-turn KV-cache-reuse regression gate (RESEARCH_236)

Adds a benchmark invariant that **guards the already-banked sticky-routing
KV-cache-reuse win** (#376 — ~64% turn-2 reuse measured 2026-07-09). Nothing
currently guards it: a routing change, coordinator config flip, or provider
prefix-cache regression could silently take the win back and no test would fail.
This is that guard.

### What it does

- **New scenario** `test/network-harness/scenarios/16_sticky_cache_reuse.yaml` —
  a sticky multi-turn conversation with a large (~3–4k-token) shared prefix and
  per-turn divergent tails (so it exercises real prefix-cache reuse, not an
  identical-prompt `nothing_new` artifact), plus an uncached control turn.
  `stream: false` so the terminal `usage` frame is reliably present. Prod-safe
  (light: a handful of requests, cents).
- **Harness capture** — `buyer.Result` + `loadgen.go` now record
  `cached_prompt_tokens` / `prompt_tokens` from `usage` (+ presence flags),
  mirroring `probe.mjs`; SKIP (not FAIL) when a spec-strict gateway omits `usage`.
- **`B8` — sticky cache-reuse retention** (armed gate): median
  `cached_prompt_tokens / prompt_tokens` over warm turns. **PASS ≥ 0.60 (target),
  WARN [0.50, 0.60) (degrading — non-green), FAIL < 0.50 (hard floor — reuse
  collapsed).**
- **`B9` — cached-turn latency advantage** (record-only, always SKIP): records
  the cached-vs-uncached p50 latency ratio without gating.

### Calibration (from a real prod baseline, not guessed)

Ran scenario 16 against prod (`api.malibu.tech`, 30B-Coder) on 2026-07-22 with
sticky routing verified live on both sides. Measured **median reuse 0.725** over
7 warm turns (corroborating #376's ~0.64, range 0.638–0.70); cached turns ~5×
faster (p50 ~2.1s vs ~10s). Thresholds transcribed from that baseline with
headroom: the 0.50 FAIL floor sits below both the median and the #376 low end, so
deterministic prefix-cache jitter won't flap it while a genuine collapse drops
through. Evidence: `audits/2026-07-22/RESEARCH_236_baseline/`.

### Audit

Three-lane codex (code / security / architect) to 0 C/H/M. Security passed clean;
code + architect converged over R1–R6. The R5 architect HIGH — that a soft WARN
below the advertised floor broke the fail-loud promise — is resolved by making
0.50 the actual FAIL boundary (the reband above), re-audited clean in R6.

### Audit — carried LOWs (0 C/H/M met; these ship documented)

- **Baseline artifacts are pre-reband.** `audits/2026-07-22/RESEARCH_236_baseline/benchmark_verdict.json`
  records the run's old 0.50/0.30 B8 thresholds (and B9 target/bare_min). The
  *measured* values (median reuse 0.725) are valid and are what the current
  0.60/0.50 bands were transcribed from; the recorded thresholds are superseded
  by this PR. Left as-is as a dated evidence snapshot.
- **Concurrent scheduled runs can false-FAIL** (pre-existing harness-header
  limitation): the provider-cache conversation tag isn't run-salted, so two
  overlapping runs under the same buyer account can evict each other's warm
  prefix → apparent zero reuse. Fold run-salt into the `sticky_cache` tag (or
  enforce single-flight) when wiring the continuous gate. Not exercised by a
  single manual run.

### Notes

- Benchmark verdicts remain advisory (do not affect process exit) — a scheduled
  consumer must treat WARN **and** SKIP as non-green, not just FAIL. Wiring the
  continuous/CI phase-C gate is the follow-up (and is where the run-salt fix above lands).
- Cross-refs: #376 (the measured reuse this protects), SPEC-004 Pillar A (sticky
  affinity), KV-cache fix `31f708b`, scenario 03/08 + invariant B7, `probe.mjs`.
