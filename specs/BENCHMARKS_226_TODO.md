# BENCHMARKS — Re-ranked TODO after RESEARCH_223 / 224 / 225

**Status as of 2026-06-30.**
**Re-ranked from** `RESEARCH_223` Part 6 (10 SCN-223-NN scenarios)
**Informed by** `RESEARCH_224` (per-model rate-card + tier filter) and
`RESEARCH_225` (Darkbloom = d-inference, runs mlx-swift, MoE catalog,
88% subsidy share).
**Will merge with** `RESEARCH_226` (MoE selection + market demand) SCN-226-NN
scenarios when that memo lands.

This is a **tracking file**, not a normative SPEC. Update statuses
inline as bench scenarios are run, deferred, or dropped. Source of
truth for any measured number lands in a dated `specs/BENCHMARK_BASELINE_*.md`
file, not here.

---

## Priority bands

### P0 — Gating Track B v2 launch (must run before flipping live rates)

| ID | Scenario | Decision gate | Status |
|---|---|---|---|
| `SCN-223-01` | ~~Isolated M4 Air 24GB Qwen3-32B-4bit, verify model config/hash, re-measure single-stream sustained tok/s~~ **RESOLVED 2026-06-30 by code reading.** [test/network-harness/scenarios/07_sustained_throughput.yaml:68-74](test/network-harness/scenarios/07_sustained_throughput.yaml) shows scenario 07 alternates prompts between `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` AND `mlx-community/Qwen3-32B-4bit` across 2 providers (M4 Air + air5), each serving ~half per `expected_shape`. The "14-17 tok/s p50" in BENCHMARK_BASELINE is a **blended median across two model classes**, NOT isolated 32B. The 2026-06-28 baseline author's `Key finding: TTFT remains tight under concurrency. The TPS at 14 tok/s is hardware-bound (Qwen3-32B-4bit on M4 Air)` was an *unverified hypothesis* with an explicit followup TODO (`Phase-B follow-up should split TPS by provider+model`) that was never run. RESEARCH_222 / RESEARCH_223 inherited it as fact. **No anomaly: Track A's 6-7 tok/s theoretical ceiling for M4 Air × Qwen3-32B-4bit stands.** No hardware remeasurement needed for this scenario; the matrix is correct. Followup: see `SCN-NEW-05` to add per-model isolation to the harness so future baselines don't repeat the attribution error. | DONE-PASS (resolved by code reading) |
| `SCN-NEW-01` | ~~Per-model rate-card key matching test against `phase4-coordinator/internal/billing/formula.go` model-string normalization~~ **DONE-FAIL 2026-06-30 by code reading — HAZARD CONFIRMED.** [phase4-coordinator/internal/billing/formula.go:34](phase4-coordinator/internal/billing/formula.go:34) `RateFor` does **zero normalization** — uses raw buyer model string for exact map lookup; falls through to `default` row on mismatch. Cross-check against [test/network-harness/scenarios/07_sustained_throughput.yaml:68-74](test/network-harness/scenarios/07_sustained_throughput.yaml) production buyer strings `mlx-community/Qwen3-32B-4bit` + `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` vs Track B Entry 92 rate-card keys `qwen3-32b` / `qwen-2.5-coder-32b` / etc. — **none of the proposed keys match the actual buyer strings.** Wave 1 hot reload would silently overcharge **100%** of traffic at `default: $1.00/M` instead of intended `$0.220/M` (32B) / `$0.027/M` (8B). This BLOCKS Wave 1 launch. Fix paths: (a) rewrite Entry 92 rate-card row keys to match exact production model strings — fragile, new variants silently overcharge; (b) **recommended**: land SPEC-005 v0.3 delta with class-aware lookup (regex / prefix matching) — already deferred-with-spec-delta-flag in RESEARCH_224. Companion failing-Go-test (`formula_test.go::TestRateForRealBuyerStrings`) goes in a separate PR (money-path code = 3-lane codex audit per [[feedback-three-lane-codex-audits]]). | DONE-FAIL (hazard confirmed; blocks Wave 1) |
| `SCN-NEW-02` | Hardware-tier rejection telemetry: synthetic out-of-tier provider attempts 32B job; confirm rejection in audit-log + useful error code returned | Tier filter ships in next coordinator release per Track B; must observably enforce, not silently accept. | TODO |
| `SCN-NEW-03` | End-to-end billing smoke at new rates: 1 test buyer + 1 M-Max provider, 1k completions through `qwen3-32b` row, confirm billing rows show $0.220/M (not $1.00 default) | Confirms rate-card row hot-reload (SIGHUP) actually applied; catches normalization mismatch in flight. | TODO |
| `SCN-NEW-05` | Per-model isolated bench: fork [test/network-harness/scenarios/07_sustained_throughput.yaml](test/network-harness/scenarios/07_sustained_throughput.yaml) into `11_isolated_model_tps.yaml` that fires only ONE model per provider per run (single-model, single-provider) and reports per-(provider, model) TPS rather than blended p50. Run for {`Qwen3-32B-4bit` × M4 Air, `Qwen2.5-Coder-7B-Instruct-4bit` × M4 Air, `Qwen3-32B-4bit` × M4 Max once available} so future baselines have clean per-cell numbers. | Prevents the SCN-223-01 attribution error from recurring. Feeds RESEARCH_223 matrix verification. Not a launch blocker; data-quality investment. | TODO |

**Decision gate**: status as of 2026-06-30 after first investigation pass:

- SCN-223-01: **DONE-PASS** by code reading (no hardware needed)
- SCN-NEW-01: **DONE-FAIL** by code reading — **Wave 1 BLOCKED**
- SCN-NEW-02: TODO (needs Wave 2 tier filter to exist)
- SCN-NEW-03: TODO (needs SCN-NEW-01 fix landed first or rewritten rate-card keys)
- SCN-NEW-05: TODO (data quality follow-up; not a launch blocker)

**New blocker**: Wave 1 hot reload cannot ship as designed because the
current `RateFor` lookup is exact-string-match and Entry 92's proposed
rate-card row keys don't match the buyer-side model strings observed
in production scenarios. **Either rewrite Entry 92 keys to exact-match
strings (fragile) OR land SPEC-005 v0.3 class-aware-lookup delta first
(recommended).** This was foreseen and flagged in Entry 92 + RESEARCH_224
but is now empirically confirmed by reading the actual code path.

`SCN-223-01` separately gates whether `RESEARCH_223` matrix needs to
be re-built — **answered NO**: matrix ceilings stand; only the inherited
"observed 14 tok/s" narrative in RESEARCH_222 + RESEARCH_223 prose needs
a correction note (the matrix cells themselves were already correct
per bandwidth math).

### P1 — Track B v2 monitoring (run during 90-day beta cohort)

| ID | Scenario | Decision gate | Status |
|---|---|---|---|
| `SCN-223-10` | 30-min thermal soak on M4 Air / M4 Max / M2 Ultra during sustained Qwen3-32B-4bit decode; report TPS curve, throttle point | Realistic-sustained TPS != peak. Feeds Track B provider $/hr math for all tiers. Air may drop 10-25%; Max/Ultra should hold. | TODO |
| `SCN-223-08` | Llama-3.3-70B-4bit on M2 Ultra / M3 Ultra under mlx-swift and llama.cpp; single-stream sustained + 2-stream concurrent | Tier-S serves 70B per Track B at $0.250/M. Need confirmed S=20-30, C=40-65 before quoting Tier-S provider $/hr in cohort onboarding. | TODO |
| `SCN-NEW-04` | Cohort onboarding dry-run: simulate 5 providers (1 S, 2 A, 1 B, 1 C) registering with hardware probe; verify tier assignment lands correctly and off-chain token ledger writes the expected rows | Token ledger Option α is operator bookkeeping. Confirm the schema works under a realistic provider mix before cohort cap of 120 onboards. | TODO |

### P2 — Strategic-direction-gated (run if dense-32B differentiation locks in)

These were Track A's engineering-roadmap-driving benchmarks. Darkbloom's
production stack (mlx-swift, MoE-with-small-active) shifts whether
they're load-bearing. Hold until after `RESEARCH_226` MoE memo lands
to decide dense-vs-MoE direction.

| ID | Scenario | Decision gate | Status |
|---|---|---|---|
| `SCN-223-04` | llama.cpp `--parallel 4 --cont-batching` Qwen3-32B-Q4_K_M on M4 Max; aggregate + per-stream TPS | **Reframe**: compare against mlx-swift baseline on same workload. Decision is "do we swap runtimes?", not "does llama.cpp work." | DEFERRED — gate on RESEARCH_226 strategic pick |
| `SCN-223-05` | Concurrent-streams ceiling on **mlx-swift** runtime (the actual production stack per Darkbloom) with Qwen3-32B-4bit on M4 Max / M2 Ultra | **Reframe**: original was vllm-mlx / mlx-openai-server which is too new. Replace with current-runtime headroom test. Informs whether continuous-batching engineering is needed at all. | DEFERRED — reframe required |
| `SCN-223-03` | Qwen3-0.5B drafting Qwen3-32B speculative decode on M4 Air + M4 Max; sustained TPS + draft acceptance rate | Track A #2 engineering bet (1-2 EM, 1.2-2.0× per stream). Only relevant if dense 32B is the lane. | DEFERRED — gate on RESEARCH_226 strategic pick |
| `SCN-223-07` | 3-bit MLX Qwen3-32B-4bit quality (MMLU + HumanEval delta vs 4-bit baseline) + throughput | If quality holds, +15-35% TPS shifts M4 Max 32B from electricity-plus into meaningful USD margin. Only relevant if dense 32B is the lane. | DEFERRED — gate on RESEARCH_226 strategic pick |

### P3 — Low-priority / hygiene

| ID | Scenario | Status | Rationale |
|---|---|---|---|
| `SCN-223-02` | Swift MLX (`ModelRuntime.swift`) vs `mlx_lm.generate` Python reference parity on same model + prompt | LOW-PRI | Runtime-correctness hygiene check. Our runtime should agree with reference within 20%. Useful but not blocking. |
| `SCN-223-09` | Prefix-cache reuse on repeated agent prompts; TTFT/prefill delta vs decode delta | DEFERRED | Independent of model class; helps any agent traffic. Defer until actual agent workloads exist to optimize against. |

### Superseded / cross off

| ID | Scenario | Why superseded |
|---|---|---|
| `SCN-223-06` | KV-cache pressure on M4 Air 24GB with 4×4K-context Qwen3-32B-4bit streams | Track B's hardware-tier filter explicitly prevents routing 32B to Tier-C (M4 Air). Expected outcome (OOM / page pressure) is already encoded in the routing decision; benchmark answers "would it work if we did the thing we're not going to do." Repurpose for MoE 20B-class on M4 Air if/when that lane opens (see SCN-226-NN). |

---

## SCN-226-NN — RESEARCH_226 MoE benchmarks (merged 2026-06-30)

`RESEARCH_226` landed and added MoE rows to Track B's rate-card.
These 5 scenarios validate the per-cell TPS estimates that the MoE
rate-card and per-model admission rules depend on.

| ID | Scenario | Decision gate | Status |
|---|---|---|---|
| `SCN-226-01` | M4 Air 24GB and 32GB × `openai/gpt-oss-20b` MXFP4/4bit under MLX and llama.cpp GGUF; 4K prompt, 512 completion, 3 runs | Promote `gpt-oss-20b` to Tier-C M4 Air 32GB+ in `model_admission`. Success: ≥30 sustained tok/s, no swap, p95 TTFT ≤2500 ms. | TODO |
| `SCN-226-02` | M4 Air 32GB, M4 Pro 24GB/48GB × `google/gemma-4-26b-a4b-it` 4bit and QAT-4bit under MLX/VLM and llama.cpp GGUF; 4K text-only + 4K multimodal-disabled text path | Promote `google-gemma-4-26b-a4b-it` to Tier-C 32GB+; gate Tier-B 24GB on this bench. Success: ≥30 tok/s Tier-C, ≥45 tok/s Tier-B, stable memory. | TODO |
| `SCN-226-03` | M4 Max 64GB/128GB and M3 Ultra 256GB × `qwen/qwen3-30b-a3b` 4bit under MLX/LM Studio and llama.cpp; 4K prompt, 2K completion, `/no_think` and thinking variants | Track A runtime-reliability gate that promotes Qwen3-30B-A3B from ⚠️ to ✅. Success: Tier-A ≥70 tok/s non-thinking; Tier-S ≥90 tok/s. | TODO |
| `SCN-226-04` | M4 Max 64GB and M2 Ultra 128/192GB × `qwen/qwen3-next-80b-a3b-instruct` 4bit under MLX and GGUF; 4K and 32K prompts | Unlocks Tier-A 64GB+ for Qwen3-Next-80B as a holdout MoE. Success: load without swap; Tier-A ≥35 tok/s at 4K; 32K degradation recorded. | TODO |
| `SCN-226-05` | M2 Ultra 192GB and M3 Ultra 256GB × `minimax/minimax-m2.7` 4bit GGUF under llama.cpp latest; 4K prompt, 512 completion, batch 1 and 2 | **Prove or kill** Tier-S MiniMax listing. Success: ≥25 tok/s single stream and no swap → list. Fail → drop MiniMax from v2 consideration. | TODO |

### Priority placement

- `SCN-226-01` + `SCN-226-02` → **P0** (gate v2 MoE-row launch — without these the per-model admission rules in `RESEARCH_226` Part 5 are unverified)
- `SCN-226-03` → **P1** (decides whether `qwen3-30b-a3b` enters at v2 launch ✅ or stays ⚠️)
- `SCN-226-04` + `SCN-226-05` → **P2** (capability expansion beyond v2 launch; not gating)

### Repurposed SCN-223-06 slot

`SCN-223-06` (KV-cache pressure on M4 Air 24GB × dense Qwen3-32B with
4×4K-context streams) was superseded by Track B's tier filter. The
slot is now naturally re-occupied by **SCN-226-01** (same hardware,
different model: MoE GPT-OSS-20B with 3.6B active fits where dense
32B doesn't — the bench that proves the per-model admission unlock).

---

## Cross-reference: which research memo each scenario informs

| Scenario | RESEARCH_223 (MLX roadmap) | RESEARCH_224 (pricing v2) | RESEARCH_225 (Darkbloom) | RESEARCH_226 (MoE) |
|---|:-:|:-:|:-:|:-:|
| SCN-223-01 | x | x (rate-card math) | | |
| SCN-223-02 | x | | | |
| SCN-223-03 | x | | | |
| SCN-223-04 | x | | x (comp vs darkbloom stack) | |
| SCN-223-05 | x | | x | |
| SCN-223-06 | (superseded) | (superseded by tier filter) | | (re-use for MoE on Air) |
| SCN-223-07 | x | x (margin on M-Max 32B) | | |
| SCN-223-08 | x | x (Tier-S 70B) | | |
| SCN-223-09 | x | | | |
| SCN-223-10 | x | x (sustained vs peak) | | |
| SCN-NEW-01 | | x (model-key normalization) | | |
| SCN-NEW-02 | | x (tier filter telemetry) | | |
| SCN-NEW-03 | | x (rate-card hot-reload smoke) | | |
| SCN-NEW-04 | | x (token-ledger cohort dry-run) | | |
| SCN-226-NN | (some) | x (MoE rate-card delta) | | x |

---

## Open questions to resolve as benches run

1. **If SCN-223-01 confirms 14 tok/s is correct** (not bench attribution
   error), what's the missing factor vs 6-7 theoretical ceiling? Speculative
   decode silently enabled? Lower quantization than declared? Smaller model
   variant? This changes the whole `RESEARCH_223` Part 2 matrix downward
   in expected gap-to-H100, since bandwidth-bound math would then need
   recalibration.

2. **If SCN-NEW-01 finds model-string normalization mismatch**, decide:
   patch the rate-card row keys to match actual buyer-requested model
   strings, or add a class-level rate-card lookup (SPEC delta to SPEC-005,
   per RESEARCH_224 caveat).

3. **If SCN-223-08 70B numbers come in below the 20-30 / 40-65 range**,
   Tier-S × 70B at $0.250/M won't even cover electricity. Decision:
   raise 70B rate-card row, remove 70B eligibility from Tier-S until
   Ultra fleet TPS improves, or accept it as donor-class for cohort
   prestige.

4. **If SCN-226-NN MoE TPS matrix shows M4 Air can serve GPT-OSS 20B at
   ≥50 tok/s sustained**, Track B's tier filter needs an exception: allow
   Tier-C providers to take MoE-small-active jobs even though they can't
   take dense-32B. Probably a `min_active_param_gb` field per rate-card
   row rather than a tier override.

---

## Update protocol

- Run a bench → record raw numbers in `specs/BENCHMARK_BASELINE_<date>.md`
  (or scenario subdirectory if there are >5 numbers).
- Update the relevant row's `Status` column here: TODO → RUNNING → DONE-PASS / DONE-FAIL / DEFERRED.
- If a result contradicts an assumption in `RESEARCH_223/224/225`, flag
  in conversation immediately — don't silently update the matrix.
- When `RESEARCH_226` lands, merge SCN-226-NN rows in place above and
  delete the placeholder block.
