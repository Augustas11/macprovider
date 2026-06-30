# RESEARCH PROMPT — MLX continuous-batching / speculative-decoding state of the art and 12-month engineering roadmap

Run as: `omc ask codex "$(cat specs/RESEARCH_223_MLX_THROUGHPUT_ROADMAP_PROMPT.md)"`

This is a **technical research prompt**, not a code-audit prompt. Single
codex call (or twice with different models). Output is a roadmap memo,
not a diff. Pair-track of [RESEARCH_224_PRICING_V2_PROMPT.md] —
pricing v2 depends on whether the per-cell tok/s targets here are
believable inside 6-12 months.

---

## Task

Macprovider providers run MLX-quantized LLMs on Apple Silicon and
compete on $/M-token pricing against datacenter GPU providers
(OpenRouter, Together, DeepInfra, Groq). Current single-stream
throughput is structurally ~10-50× behind H100/H200 batched inference
due to (a) memory bandwidth ceiling, (b) lack of mature continuous
batching on MLX, (c) tiny KV-cache budget on consumer Apple Silicon.

Audit the **actual** state of the art for high-throughput LLM serving
on Apple Silicon as of 2026-06-30 and produce a **12-month engineering
roadmap with concrete realistic sustained tok/s targets per
(hardware, model-class, software-config) cell**.

The output feeds two downstream decisions:
1. Which hardware tiers the network should accept as providers
2. Which model classes each tier is routed to
3. Whether per-tier USD economics ever close, or whether token issuance
   is the only viable subsidy mechanism

---

## Background — current state (verbatim)

**Observed bench** (`BENCHMARK_BASELINE_2026-06-29.md` scenario 07):
- Qwen3-32B-4bit on M4 Air sustains **14 tok/s**, single stream
- (Theoretical memory-bandwidth-bound peak is ~6-7 tok/s — the
  observed 14 is suspicious; investigate whether the bench is using a
  smaller-than-32B variant, lower quantization, or some pipelining
  trick)

**Provider runtime stack**:
- Swift CLI in `phase3-binary/Sources/macprovider-cli/`
- Shells out to MLX via Python sidecar (current shape — confirm path)
- Coordinator: `phase4-coordinator/` admission control + billing
- Gateway: OpenAI-compat API, streaming

**Hardware fleet today** (rough — confirm against network telemetry
if available):
- Predominantly M4 Air providers
- Small number of M4 Max + M2 Ultra
- No M3 Ultra yet

**Theoretical memory-bandwidth ceilings for 32B-4bit (~18GB)**:
| Hardware | Bandwidth | Peak single-stream tok/s |
|---|---:|---:|
| M4 Air | ~120 GB/s | ~6-7 |
| M4 Max | ~410 GB/s | ~22 |
| M2 Ultra | ~800 GB/s | ~44 |
| M3 Ultra | ~800 GB/s | ~44 |
| H100 | ~3,350 GB/s | ~180 |
| H200 | ~4,800 GB/s | ~265 |

---

## What to produce

### Part 1 — State-of-the-art audit

For each subsystem below, report: what exists, license, maturity, who
maintains it, last release/commit date, production-readiness for a
real provider runtime serving paying buyers. Cite GitHub URLs and
exact commits/releases.

**1.1 Continuous batching / PagedAttention equivalents on Apple Silicon**
- `mlx-lm`, `mlx-server`, `mlx-omni-server`
- LM Studio's local API server (closed-source but observable)
- Ollama on Apple Silicon (concurrency model, default `OLLAMA_NUM_PARALLEL`)
- llama.cpp `--parallel` + `--cont-batching` (Metal backend)
- `mlx-vlm`, `mlx-graphs` research repos
- Anything resembling vLLM's PagedAttention with KV-cache paging on MLX
- Production systems known to serve ≥5 concurrent streams of a 32B-class
  model on Apple Silicon at sustained throughput

**1.2 Speculative decoding on Apple Silicon**
- `mlx-lm` speculative-decoding (draft-model selection, measured
  speedups on M-series)
- llama.cpp speculative support
- EAGLE / Medusa / Lookahead decoding — any MLX ports
- Self-speculative variants (no separate draft model)

**1.3 Quantization frontier**
- 4-bit baseline (current): MLX `Q4`, GGUF `Q4_K_M`
- 3-bit: MLX 3-bit, AWQ-3, GGUF `Q3_K_S`
- 2-bit: GGUF `IQ2_XXS`, AQLM
- K-quants / mixed-precision (attention 4-bit, MLP 2-bit)
- Measured quality degradation vs throughput gain on
  Qwen3-32B / Llama-3.1-8B / Llama-3.3-70B

**1.4 Kernel-level optimizations**
- MLX kernel roadmap (Apple's stated improvements, recent merged PRs,
  release cadence)
- AMX matrix unit utilization in MLX vs llama.cpp
- Apple Neural Engine (ANE) — anyone serving transformer decode via
  ANE+CoreML in production
- Metal Performance Shaders fused attention (FlashAttention-equivalent
  on Apple)

**1.5 Architectural alternatives**
- MoE on Apple Silicon (Mixtral 8x7B, Qwen3-MoE) — does activated-
  params bandwidth win on M-Ultra?
- State-space models (Mamba-2) on MLX
- Smaller models with better quality (Qwen3-7B full-precision vs
  Qwen3-32B-4bit) — is this just better per-token TCO?

### Part 2 — Realistic per-cell tok/s targets

Build this matrix with **realistic sustained tok/s** (single-stream and
max-concurrent under the best in-tree software stack), dated **today**,
**6 months out**, and **12 months out** from 2026-06-30. Each cell must
cite the software config assumed (engine, speculative on/off,
quantization, concurrent batching level).

| Hardware | Model class | Today S | Today C | 6mo S | 6mo C | 12mo S | 12mo C |
|---|---|---|---|---|---|---|---|
| M4 Air 16GB | 7-8B (Llama-3.1-8B, Qwen3-7B) | | | | | | |
| M4 Air 24GB | 7-8B | | | | | | |
| M4 Air 24GB | 32B-4bit (Qwen3-32B) | | | | | | |
| M4 Pro 24GB | 7-8B | | | | | | |
| M4 Pro 48GB | 32B-4bit | | | | | | |
| M4 Max 64GB | 7-8B | | | | | | |
| M4 Max 64GB | 32B-4bit | | | | | | |
| M4 Max 128GB | 70B-4bit (Llama-3.3-70B) | | | | | | |
| M2 Ultra 128GB | 32B-4bit | | | | | | |
| M2 Ultra 192GB | 70B-4bit | | | | | | |
| M3 Ultra 256GB | 32B-4bit | | | | | | |
| M3 Ultra 256GB | 70B-4bit | | | | | | |

Then add reference rows: **H100 single-stream and batched (32 streams)**
for the same model classes, so the gap is visible at a glance.

Be explicit about which numbers come from **published benchmarks**
(cite URL) vs **vendor claims** vs **extrapolation from bandwidth
ceiling**. Flag aspirational targets that assume software not yet
released.

### Part 3 — Engineering bets ranked by ROI

Rank each candidate engineering bet by **expected effective-throughput
multiplier per engineer-month invested**. Candidates:

- MLX continuous-batching contribution (PR to `mlx-lm`)
- MLX PagedAttention port
- Speculative-decoding integration into provider runtime
- 3-bit MLX quantization adoption (provider-side model conversion)
- ANE backend for decode (CoreML path)
- MoE model support
- llama.cpp `--parallel` swap-in as runtime alternative
- Custom Metal kernel work (FlashAttention fork)
- Hardware-tier-aware draft-model selection
- Prefix-cache reuse across requests

For each: engineer-month cost (point estimate + range), expected
throughput multiplier (per stream AND per machine), risk / probability
of success, external dependencies (Apple ships X, upstream OSS
releases Y), which hardware tiers benefit.

Highlight bets that hit **>2× effective per-machine throughput in
<3 engineer-months at <30% risk**.

### Part 4 — 12-month roadmap recommendation

Pick **ONE** of:

**Roadmap A — Buy the gap (hardware focus).** Stop optimizing M4 Air.
Recruit M4 Max / M-Ultra owners. Engineering = match continuous-
batching maturity on the high-bandwidth tier where it actually pays.

**Roadmap B — Software arbitrage (engineering focus).** Bet MLX
continuous batching + spec decode lands in 12 months and we are first
to expose it productized. Heavy investment in `mlx-server` / `mlx-lm`
upstream. Keep M4 Air on the network but route only 7-8B traffic.

**Roadmap C — Model-class specialization.** Don't serve 32B on M4 Air
at all. Build the network around (a) small-fast models on entry Apple
Silicon, (b) 70B-class on Ultra. Skip the structurally broken
32B-on-laptop cell.

**Roadmap D — Hybrid.** Software wins on M-Ultra + model-class routing
on M4 Air. Specify allocation, milestones, hardware spend.

If none fit, propose your own. Be concrete: name the GitHub repos and
PRs to contribute, hardware acquisition spend, per-quarter milestones,
go/no-go gates.

### Part 5 — Pricing-table implications (feeds RESEARCH_224)

For each cell in the Part 2 matrix at the **12-month** column, compute
**provider USD $/hr** at three pricing scenarios:

| Scenario | Multiplier | UsdPerMcredit | Buyer $/M comp |
|---|---:|---:|---:|
| Current default | 1.0 | 1.0 | $1.00 |
| Buyer-competitive (undercut OpenRouter Qwen3-32B $0.28/M) | 0.25 | 1.0 | $0.25 |
| Buyer-competitive vs Groq 8B ($0.04/M) | 0.04 | 1.0 | $0.04 |

For each (hardware, model-class) cell at 12-month TPS targets,
highlight which cells clear electricity floor and which clear B6
bare-min ($0.30/hr) under each pricing scenario. Use realistic
sustained TPS, not peak.

This is the bridge to the pricing decision: it tells us which hardware
tiers can ever be USD-viable at market-competitive buyer prices.

### Part 6 — Open questions and follow-up benchmarks

List 5-10 specific things to measure on real hardware to validate the
roadmap. Examples:
- Benchmark `mlx-lm` speculative decode with Qwen3-0.5B drafting
  Qwen3-32B on M4 Air; measure tok/s and draft-acceptance rate
- Run llama.cpp `--parallel 4 --cont-batching` on M4 Max with
  Qwen3-32B-Q4_K_M; measure aggregate tok/s and per-stream tok/s
- Measure KV-cache memory under 4 concurrent 4K-context streams vs
  available headroom on a 24GB M4 Air

For each, name the bench scenario id to add to
`BENCHMARK_BASELINE_*.md` and the expected ranges to falsify/confirm.

---

## Out of scope

- Buyer-side USD pricing (covered in RESEARCH_224)
- Crypto token issuance design (covered in RESEARCH_224)
- Coordinator / gateway code changes (memo-only research)
- New SPEC documents (this produces a memo, not normative SPEC)
- Apple Silicon training (we serve inference only)

## Output format

Markdown memo, **~600-1000 lines**. Tables for Parts 1, 2, 3, 5. Prose
for Part 4. Cite every claim about library state with the **GitHub
URL, commit/release date, and what you observed** (issue thread,
README, benchmark blog post). Flag aspirational vendor claims vs
measured benchmarks explicitly. Conservative > optimistic — this
roadmap feeds money decisions.
