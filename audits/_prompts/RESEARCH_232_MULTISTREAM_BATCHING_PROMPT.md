# RESEARCH PROMPT — Multi-stream / continuous batching on Apple Silicon for macprovider

Run as: `omc ask codex "$(cat audits/_prompts/RESEARCH_232_MULTISTREAM_BATCHING_PROMPT.md)"`

This is a **technical research prompt**, not a code-audit prompt. Single
codex call (or twice with different models). Output is a decision-grade
memo, not a diff.

**Status:** PARKED for a future implementation session. Research first;
no runtime changes in the research turn.

**Explicit non-goal:** adopt oMLX as macprovider's inference engine.
oMLX is one reference implementation (mlx-lm `BatchGenerator`); evaluate
its **architecture**, not its deployment packaging.

**Upstream context:**
- [RESEARCH_223_MLX_THROUGHPUT_ROADMAP_MEMO.md] — identified continuous
  batching as the largest structural throughput gap vs datacenter GPUs
- [RESEARCH_231_OMLX_BENCHMARK_CATALOG_PROMPT.md] — oMLX benchmark data
  for catalog calibration (separate track)
- `beta/throughput-engineering/` runbook — T0–T3 perf tasks
- Entry 110 (DECISION_CRITERIA) — `max_concurrency_override` / `--max-batch`
  slot policy by chip class

---

## Task

Macprovider providers today gate concurrent inference with
`AsyncSemaphore` + `--max-batch` (default 1; autotune explores 2; M-Max
48GB+ may get 2–4 slots per Entry 110). This is **parallel
single-stream decode**, not **continuous batching** (shared forward pass
across requests at the same decode step).

Audit the state of the art for **true multi-stream batching** on Apple
Silicon MLX stacks as of 2026-07-09 and recommend **one primary
approach** for macprovider to pursue in a future build session, with
fallback options and explicit go/no-go gates.

---

## Background — macprovider concurrency today

### Runtime (Swift / mlx-swift-lm 3.31.4)

| Component | Path | Behavior |
|---|---|---|
| Concurrency gate | `ModelRuntime.swift` `AsyncSemaphore` | Limits in-flight requests |
| `maxBatch` CLI flag | `MacProviderCLI.swift` | Passed to semaphore value |
| Generation | `TokenIterator` / `generate` | One stream per acquire |
| Autotune Stage 2 | `max_batch` ∈ {1, 2} | Knob sweep, not batch API |
| Spec decode | `generateTokens` + draft model | Per-request; not batched |
| Coordinator slots | heartbeat `slots_total` | Derived from recommendation |

**Not present:** `BatchGenerator`, paged batch scheduler, per-step multi-
request forward, aggregated TG under load.

### Observed gap (from RESEARCH_223 + oMLX marketing data)

oMLX claims up to **4.14× TG throughput at 8× concurrency** (M3 Ultra,
Qwen3-Coder-Next-8bit, pp1024/tg128). Independent testing (Mac O'Clock,
Jun 2026) found **mixed results** — sometimes mlx-lm server parallelizes
better than oMLX in specific configs. Treat all claims as hypotheses to
replicate on **macprovider catalog models**.

### Economic pressure

RESEARCH_224 concluded buyer USD pricing is market-pegged; provider upside
is per-token payout × sustained TPS. Multi-stream batching is the main
path to raise **per-machine** throughput without new hardware.

---

## What to produce

### Part 1 — Landscape audit (2026-07-09)

For each candidate system, report: license, maintainer, maturity, MLX
binding (Python/Swift), batching model, production readiness, last
release/commit.

**Required entries:**

| System | Notes |
|---|---|
| **mlx-lm `BatchGenerator`** | oMLX scheduler dependency |
| **oMLX** | Reference serving layer; extract batching design only |
| **mlx-swift-lm** | macprovider's engine; batch API presence/absence |
| **vllm-mlx** | RESEARCH_223 flagged; paged KV + batching claims |
| **mlx-server / mlx-omni-server** | Community servers |
| **llama.cpp** `--parallel` + `--cont-batching` | Metal backend alternative |
| **LM Studio** local API | Closed-source observable behavior |
| **Ollama** `OLLAMA_NUM_PARALLEL` | Concurrency semantics on Apple Silicon |

Cite GitHub URLs, release tags, and **what you verified** vs vendor
claims.

### Part 2 — Technical deep-dive: what continuous batching requires

Explain, at implementation level:

1. **Scheduler** — FCFS vs priority; how requests join/leave batch
2. **KV cache layout** — per-request slots in batched forward; paging vs
   contiguous; interaction with `kv_bits` quantization
3. **Prefill vs decode** — mixed-phase batching or decode-only batching
4. **mlx-swift-lm gap analysis** — which mlx-lm batch primitives lack
   Swift ports; read `mlx-swift-lm` issues/PRs (especially anything
   mentioning batch, paged, or continuous)
5. **Spec decode interaction** — can draft-model speculative decode
   coexist with batching? (macprovider has SPEC-028 wired)

### Part 3 — Measured throughput hypotheses to replicate

Define **5 bench scenarios** macprovider should run in a future session
(not in this research turn):

| ID | Config | Metric | Pass threshold |
|---|---|---|---|
| `MSB-01` | 1 stream, 32B-4bit, M4 Max 64GB | TG tok/s | baseline |
| `MSB-02` | 4 concurrent identical prompts | aggregate TG | > 1.5× MSB-01 |
| `MSB-03` | 4 concurrent diverse prompts | aggregate TG | > 1.2× MSB-01 |
| `MSB-04` | 2 streams, MoE 30B-A3B | aggregate TG | > 1.3× single |
| `MSB-05` | autotune `max_batch=2` native vs oMLX sidecar | TG per machine | document delta |

For each: prompt token count, decode tokens, model, knobs, expected
range from literature/oMLX data.

### Part 4 — Approach recommendation (pick one primary)

Evaluate **four approaches** for macprovider:

| ID | Approach | Summary |
|---|---|---|
| **A** | **Upstream mlx-swift-lm batch API** | Wait/contribute BatchGenerator port |
| **B** | **Native Swift scheduler in ModelRuntime** | Custom batch loop on existing APIs |
| **C** | **Out-of-process sidecar** (oMLX or mlx-lm server) | HTTP `ModelRuntimeServing` adapter |
| **D** | **llama.cpp parallel runtime** | Non-MLX stack swap for batching only |

For each: engineer-month estimate (range), expected per-machine TG
multiplier, risk %, impact on receipts/`model_hash`/warm-swap/spec-decode,
compatibility with Entry 110 slot policy.

**Deliverable:** one **primary recommendation** + one **fallback** +
explicit **no-go** options.

### Part 5 — macprovider integration map (future session)

If primary is A or B (in-process), document touch points:

| File / seam | Change |
|---|---|
| `ModelRuntime.swift` | Replace semaphore-only gate with batch scheduler |
| `ModelRuntimeServing` protocol | Unchanged vs extended? |
| `InferenceRelay.swift` | Backpressure when batch full |
| `HTTPServer.swift` | Currently hardcodes `ModelRuntime` |
| `AutotuneCommand.swift` Stage 2 | Expand `max_batch` grid |
| `CandidateProviderRunner.swift` | Probe semantics under batch |
| Coordinator `slots_total` | Mapping batch depth → advertised slots |
| OPoI / drift (`internal/pow/drift.go`) | Per-stream vs aggregate TPS |

If primary is C (sidecar), reference attestation blockers separately.

### Part 6 — 12-month milestone sketch

Quarterly milestones with go/no-go gates:

| Quarter | Milestone | Gate |
|---|---|---|
| Q3 2026 | Replicate MSB-01..03 on local hardware | ≥ 1.3× aggregate TG on one tier |
| Q4 2026 | Prototype primary approach behind flag | Receipt + relay parity on single model |
| Q1 2027 | Autotune + catalog slot policy alignment | sku-econ harness green |
| Q2 2027 | Production default for Tier-A hardware | OPoI false-positive rate < 5% |

---

## Out of scope

- Implementing batching (future BUILD_SPEC)
- oMLX benchmark → catalog calibration (RESEARCH_231)
- KV SSD persistence (RESEARCH_233)
- Buyer pricing / rate-card changes
- Normative SPEC edits in this turn

---

## Output format

Markdown memo `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`,
**~500–900 lines**.

Executive summary ≤ 12 bullets. Tables for Parts 1, 3, 4, 6. Mermaid
sequence diagram for recommended batch scheduler (optional).

Conservative > optimistic. Flag aspirational vendor throughput claims.
