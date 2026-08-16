# RESEARCH_236 — P4: multi-turn KV-cache-reuse regression gate

**Carry this in a fresh session.** Self-contained; assumes no memory of the P1/P2 sessions.
It is one of the four e2e tests proposed in the 2026-07-09 e2e-testing review (P1 canary-buyer
probe = shipped; P2 cold/warm TTFT matrix = instrument landed, campaign pending; P3 thermal soak
= `RESEARCH_235`; P4 = this).

## Why this exists

The sticky-routing + KV-cache-reuse win is **already measured and banked**, not hypothetical:
[#376](https://github.com/Augustas11/macprovider/issues/376) ("measure KV-cache reuse ratio under
real buyer patterns") is CLOSED — a live measurement on **2026-07-09** with a ~3.9k-token shared
prefix saw **~64% turn-2 prompt-cache reuse** (range **63.8–70%**), on top of the large-shared-prefix
fix `31f708b`. That reuse is worth real money (cached prompt tokens are cheap to serve) and real
latency (cached turns start faster).

Nothing currently **guards** it. A routing change that weakens sticky affinity, a coordinator
config flip, or a provider-side prefix-cache regression could silently take the win back and no test
would fail. **P4 is that guard**: a benchmark invariant that asserts, on every run, that
(a) turn-2 reuse stays above a floor, and (b) a cached turn is measurably faster than an uncached
turn. It locks in the win the way B7 locks in the cold/warm ratio.

## P4 is the runnable-now one (light load, prod-safe)

Unlike P2 and P3 — which need a lab Mac because they drive cold-loads / sustained soaks that
degrade the single prod provider (see [#584](https://github.com/Augustas11/macprovider/issues/584))
— **P4 is a light probe**: ~15–20 requests, a couple of multi-turn sticky conversations, order of
**cents** in cost, no sustained pressure. It can run against the **prod** stack
(`api.malibu.tech` / prod coordinator) now, and it is the natural continuous/CI regression gate.
The only prerequisite is that **sticky routing is ON on both sides** — verify before measuring.

## What already exists (do not rebuild)

- **The reuse-measurement recipe is proven** in the P1 canary-buyer probe,
  `test/e2e/canary-buyer/probe.mjs`: two turns sharing a **large** deterministic prefix, same
  conversation tag; on turn 2 read `usage.cached_prompt_tokens / usage.prompt_tokens`. The prefix
  **must exceed the provider's prefix-cache granularity** (probe.mjs uses ~3.9k tokens via
  `stickyPrefix()` / `stickyPrefixLines`) — with a tiny prefix, turn-2 `cached_prompt_tokens` is
  always 0 and the metric can't tell "working" from "reuse collapsed". Reuse this design exactly.
- **Sticky scenario:** `test/network-harness/scenarios/03_sticky_multi_turn.yaml` — 3 buyers × 5
  sequential turns with a per-buyer `X-MacProvider-Conversation` tag (SPEC-004 Pillar A). It
  **proves affinity** (each buyer's turns land on one provider) but its prompts are tiny
  ("pick a fruit"), so it does **not** exercise prefix-cache reuse. P4 needs a new scenario with a
  large shared prefix — model it on 03's sticky wiring + probe.mjs's prefix.
- **Cold/warm sibling:** `08_cold_warm_compare.yaml` + invariant `B7` — the closest template for a
  new ratio/threshold benchmark invariant.
- **The benchmark engine:** `test/network-harness/internal/benchmark/benchmark.go` (`B1..B7`,
  `evalB1..evalB7`, `case "Bn":` dispatch, `Verdict` struct). Thresholds also in
  `docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5.
- **Buyer capture:** `test/network-harness/internal/buyer/` (`loadgen.go`, `result.go`). **Check
  whether `buyer.Result` already records `cached_prompt_tokens` from the response `usage`.** The
  network-harness may not (it predates the reuse work); if not, you must extend the loadgen to parse
  `usage.cached_prompt_tokens` + `usage.prompt_tokens` into `Result` before the invariant can read
  them. probe.mjs already does this — mirror it. Handle the spec-strict-gateway case where `usage`
  is omitted (probe.mjs treats it as null and the metric SKIPs, not fails).

## The mission — deliverables

### Deliverable 1 — the large-prefix sticky scenario (build)

`test/network-harness/scenarios/16_sticky_cache_reuse.yaml`:
- 1–2 buyers, `stream: false` (so the terminal `usage` frame is reliably present — note the P1
  finding #511 that streaming `usage` can drop for large prompts), per-buyer sticky conversation
  tag (copy 03's `sticky_conversation_key` wiring).
- Each buyer fires **turn 1 then turn 2 sharing a large (~3–4k-token) deterministic prefix**, same
  conversation tag, so turn 2 hits the warm prefix cache on the same provider. Add a **turn 0 with a
  distinct prefix** (or a fresh conversation) as the *uncached* control for the TTFT-advantage half.
- One model class (start with the 30B, `mlx-community/Qwen3-32B-4bit`, matching 03/08). Small
  `max_tokens` (the completion is irrelevant; the prompt-cache is the subject).
- Target prod (`api.malibu.tech`) — this is the prod-safe scenario.

### Deliverable 2 — capture `cached_prompt_tokens` in the harness (build, if missing)

Extend `buyer.Result` + `loadgen.go` to record `cached_prompt_tokens` and `prompt_tokens` from each
response's `usage`, and the per-request TTFT (already captured as `TTFTMillis`). Unit-test the
parse against a fixture response with and without `usage`.

### Deliverable 3 — the regression invariants (build)

Add to `benchmark.go`:
- **`B8` (or next free ID) — "sticky cache-reuse retention":** on turn-2 requests,
  `reuse = cached_prompt_tokens / prompt_tokens`. Verdict on the median across sticky turn-2
  samples. **Floor: start at ≥ 0.40** (conservative vs the measured 0.64), tune from Deliverable 4's
  baseline. `SKIP` when `usage`/cache fields are absent (do not FAIL a spec-strict gateway).
- **`B9` — "cached-turn TTFT advantage":** `cached_turn_ttft_p50 ≤ uncached_turn_ttft_p50 × margin`
  (start margin ~0.9 — cached should be at least a little faster; tune from baseline). Requires the
  uncached control turns from Deliverable 1.
- `case` dispatch + `evalB8`/`evalB9` + unit tests in `benchmark_test.go` (fixtures for
  cache-working, cache-collapsed, and usage-absent) + rows in `SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5.
- Declare `invariants: [B8, B9]` (plus B1 if useful) in `16_sticky_cache_reuse.yaml`.

### Deliverable 4 — a baseline run + threshold calibration + wire it in

1. **Verify sticky is live** before measuring: the gateway needs `routing.sticky_enabled=true` +
   `auth.key_hash_secret` set, and the coordinator needs `routing.sticky_enabled=true` (03's header
   documents this). If sticky is off, the scenario measures nothing — confirm on the live config
   first (probe the prod config or ask; do not assume).
2. **Run `16_sticky_cache_reuse` against prod** (light, prod-safe). Record the measured reuse median
   and cached/uncached TTFT gap.
3. **Set the floors from the real number**, not a guess — transcribe the measured baseline into the
   thresholds (leave headroom below the measured median so normal jitter doesn't flap the gate).
4. **Wire it as a continuous/phase-C gate:** a scheduled run (or CI job) so a future stickiness /
   cache regression fails loud. This is the point of P4 — the measurement already exists; the gate is
   the new thing.

## Hard rules

1. **Large prefix or the metric is meaningless.** A short prefix → turn-2 `cached_prompt_tokens` = 0
   always → the invariant silently reads 0% reuse and can't distinguish "regressed" from "prefix too
   small". Use the ~3–4k-token prefix design from probe.mjs.
2. **`SKIP`, don't `FAIL`, on absent `usage`.** A spec-strict gateway may omit the usage frame; that
   is not a cache regression. Mirror probe.mjs's null handling.
3. **`stream: false` for the measured turns** so the terminal usage frame is reliably present
   (streaming `usage` can drop for large prompts — P1 finding #511).
4. **Calibrate from a real run, transcribe don't guess** (the P2 discipline): the shipped thresholds
   come from Deliverable 4's baseline, with headroom, not from intuition.
5. **Keep the PR fresh** — rebase on `origin/main` at session start and before opening the PR;
   attribution-check any red CI against the base commit.

## Repo conventions (must follow)

- **Fresh worktree off `origin/main`** for all code work — never edit the canonical checkout
  (project `CLAUDE.md`, "Worktree isolation").
- Harness/invariant changes go through the **three-lane codex audit** (code / security / architect
  via `omc ask codex`) to **0 C / 0 H / 0 M** before PR, authored as **Augustas11** so antfleet-ops
  can review. Prompts/results under `audits/`, never `specs/` (CI gate).
- **Never print the buyer token** (`~/.config/macprovider/buyer-api-key`); the harness reads
  `${BUYER_TOKEN}`.
- Cross-refs: #376 (the measured reuse this gate protects), SPEC-004 Pillar A (sticky affinity),
  KV-cache fix `31f708b`, scenario `03`/`08` + invariant `B7`, `probe.mjs` (the proven reuse recipe),
  and the sibling P3 soak (`RESEARCH_235`).
