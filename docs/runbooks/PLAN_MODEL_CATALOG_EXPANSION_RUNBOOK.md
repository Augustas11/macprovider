# PLAN — Model Catalog Expansion Runbook

**Version:** 0.1.13  
**Date:** 2026-07-09  
**Status:** PARKED — P0–P2 complete; P3-R231 gate work scoped to executor limits (not normative spec)  
**Source analysis:** Model-catalog expansion exploration (2026-07-07 Cursor session)  
**Pinned session role:** This document is the **single plan-of-record**. Executor agents update task status here; the pinned planning session verifies gates and revises sequencing.

---

## How to run this plan

1. **Pinned session (this chat):** verify P0 evidence, approve phase transitions, update version/status in this file.
2. **Executor agents (separate chats):** one agent per task ID below. Each agent:
   - Works in a **fresh worktree** off `origin/main` if making code/catalog changes (`CLAUDE.md` § worktree isolation).
   - Reads only its task section + prerequisites.
   - Produces the listed **Artifacts** under `beta/catalog-expansion/` (create dir on first run).
   - Updates the **Status tracker** table at the bottom of this file (or posts artifact paths back to pinned session for update).
3. **Do not skip P0.** Phases P1–P4 assume P0 gates are GREEN or explicitly WAIVED with rationale in `beta/catalog-expansion/P0_SUMMARY.md`.
4. **Do not bench impossible models on the executor.** See § *Executor hardware profile* before any load, autotune, or gate-setting task. oMLX advisory data does **not** override these hard limits.

### Executor hardware profile (mandatory)

> **Locked 2026-07-09** after RESEARCH_231 hardware-fit review. This Mac is the **only** catalog bench executor today; it cannot bootstrap models outside this envelope.

| Field | Value |
|-------|-------|
| **Machine** | MacBook Air (Mac17,3) |
| **Chip** | Apple M5 (10 cores) — **Tier-C** (`BandwidthTier.derive`) |
| **RAM** | **32 GB** unified (`hw.memsize` = 34,359,738,368) |
| **48 / 64 GB tiers** | **Not available** on this executor |
| **Proven bench history** | P0-01, P1-01, P2-02 (gpt-oss, Gemma-4 26B A4B, Qwen3-8B) |

### Bench eligibility rules (hard — no exceptions)

An executor agent **must not** attempt `serve`, `autotune`, `decode-bench`, or gate derivation on this Mac when **any** rule fails:

| # | Rule | Rationale |
|---|------|-----------|
| **E1** | Estimated resident weights + KV@4k + **4 GB headroom ≤ 28 GB** | Autotune admission uses `memoryGB − 4` on 32 GB (`SPEC-023` §5) |
| **E2** | Target catalog `min_bandwidth_tier` is **`C`** | Executor is M-Base; Tier-B/A gates need Tier-B/A hardware |
| **E3** | `config.json` `model_type` matches mlx-swift-lm **text** registry (P0-05 style) | VLM / `*ForConditionalGeneration` pins with `vision_config` are **out of scope** here |
| **E4** | Model is not a **new row** requiring Tier-B+ economics | RESEARCH_231 P1 candidates (e.g. Qwen3.6-35B-A3B @ ~20.4 GB, tier B) need **M4 Max 48 GB+** |

**Do not run “load probes” or “maybe it fits” experiments** on models that fail E1–E4. Use oMLX data as advisory input only; schedule off-executor hardware for local repro.

### Executor bench envelope (what this Mac *can* bootstrap)

| Class | Example models | Max resident observed / estimated | Status on executor |
|-------|----------------|-----------------------------------|--------------------|
| Small dense ≤8B | `qwen3-8b`, Llama 3.1/3.2 3B | ~5–7 GB | **OK** — P2-02 validated |
| Small MoE ≤20B nominal | `gpt-oss-20b` | ~11 GB | **OK** — P1-01 sanity |
| Mid MoE ~26–30B nominal | `gemma-4-26b-a4b-it`, `qwen3-coder-30b-a3b` | ~15–17 GB | **OK** — P0-01 / catalog live; tight at 32 GB |
| Mid MoE ~35B / dense 32B | `Qwen3.6-35B-A3B`, `qwen3-32b`, `qwen2.5-coder-32b` | ~19–22 GB+ | **BLOCKED** — exceeds safe envelope and/or tier |
| Nemotron-30B-A3B local falsification | `nvidia/nemotron-3-nano-30b-a3b` | ~32 GB `min_ram_gb`; never locally benched | **BLOCKED** — oMLX-only gate deltas until Tier-B HW |
| Flagship / Tier-A | P4-01..03 candidates | 48 GB+ | **BLOCKED** — already G5 |

### Artifact layout

```
beta/catalog-expansion/
  P0_SUMMARY.md                 # rollup after P0-01..05
  P0-01-moe-memory-parity.md
  P0-02-tier2-catalog-snapshot.md
  P0-02-tier2-catalog-snapshot-rerun.md
  P0-03-hf-weights-audit.md
  P0-04-gemma4-template-probe.md
  P0-05-nemotron-model-type.md
  P0-06-tier2-republish.md
  P1-gemma4-bench-matrix.md
  P1-gemma4-catalog-rollout.md
  P2-small-tier-catalog.md
  P3-vlm-decision.md
  P3-r231-gate-calibration.md
  P4-flagship-bench.md
```

---

## Decision gates (master)

| Gate | Requires | Blocks |
|------|----------|--------|
| **G0** | All P0 tasks GREEN or WAIVED | P1 runtime bench |
| **G1** | P1 bench PASS on ≥2 RAM tiers | Gemma-4 catalog publish |
| **G2** | G1 + rate-card + tier-2 hash signed | Prod recommendable |
| **G3** | P2 artifacts + G2 stable 48h *(waivable in pre-beta — see tracker)* | Small-tier publish |
| **G4** | P3 decision record (VLM yes/no) | Any VLM engine work |
| **G5** | P4 bench on Tier-A hardware | Flagship catalog rows |
| **G6** | RESEARCH_231 gate/new-row work: local bench only on eligible executor HW (§ Executor hardware profile) | oMLX-only catalog publishes without required tier hardware |

---

# P0 — Resolve unverified assumptions (run first)

> **Goal:** Turn exploration §9 unknowns into evidence before catalog or engine bets.

---

## P0-01 — MLX MoE memory parity (ml-explore vs Darkbloom fork)

| Field | Value |
|-------|-------|
| **ID** | `P0-01` |
| **Question** | Does MacProvider’s pinned `mlx-swift-lm` 3.31.4 (`ml-explore`, rev `bd4b7434`) exhibit comparable **resident MoE RAM** to Darkbloom’s post-v0.7.4 fork (fused gate+up cache deleted; ~8–15 GiB reclaimed per `digests/2026-07-06.md`)? |
| **Prerequisites** | `phase3-binary` builds; one 32 GB Mac available |
| **Read-only on** | `d-inference` / Layr-Labs source (**forbidden** per clean-room) |

### Procedure

1. On a 32 GB Mac, load **`mlx-community/gemma-4-26b-a4b-it-4bit`** via MacProvider serve path or minimal `swift run` harness using `LLMModelFactory.shared.loadContainer` (same as `ModelRuntime.swift:1887`).
2. Record **RSS / MLX active memory** at idle after load and after one 4K-token generation (use Activity Monitor + provider logs, or `memory_pressure` snapshot).
3. Repeat with **`mlx-community/gpt-oss-20b-MXFP4-Q8`** (already in live catalog) as control.
4. Compare resident GB to RESEARCH_226 estimates (Gemma ~14–16 GB, gpt-oss ~11 GB) and catalog `min_ram_gb` (24–28).
5. Document whether load fits **32 GB with ≥4 GB headroom** (MacProvider autotune gate: `memoryGB - 4`, `AutotuneRecommend.swift:898`).

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Gemma-4 resident ≤18 GB measured; 32 GB Mac passes load + 4K gen without swap |
| **YELLOW** | Resident 18–22 GB; fits 32 GB tight but fails 24 GB — document min_ram_gb recommendation |
| **RED** | OOM or swap on 32 GB; resident >22 GB — **blocks P1** until MLX pin upgrade or admission fix |

### Artifacts

- `beta/catalog-expansion/P0-01-moe-memory-parity.md` — table: model, quant, measured resident GB, chip, RAM tier, pass/fail

**TPS caveat:** Resident RAM conclusions are reliable; **~7.7 tok/s Gemma TPS is not** — see P1-01 contamination caveat. P0-01 executor noted dev-provider contention and gpt-oss depression vs catalog anchor (~16.7 vs ~9–11).

---

## P0-02 — Production tier-2 catalog snapshot

| Field | Value |
|-------|-------|
| **ID** | `P0-02` |
| **Question** | What models are in **production** `tier2-catalog.json` and do they match live `autotune-candidates.json`? |
| **Prerequisites** | Coordinator read access or operator can curl production static URLs |

### Procedure

1. Fetch live autotune catalog: `https://coordinator.malibu.tech/static/autotune-candidates.json` (see `AutotuneRecommend.swift:749`).
2. Obtain production tier-2 catalog:
   - **Preferred:** read-only from Pearl VPS `/opt/macprovider/tier2-catalog.json` (`coordinator.yaml:202`), OR
   - `GET https://coordinator.malibu.tech/catalog/current` / pubkey endpoints per `buyer/server.go`.
3. Diff: catalog keys, `model_id`, `sha256`, `min_ram_gb` per `tier2/catalog.go:32–40`.
4. Note whether `google-gemma-4-26b-a4b-it` or Gemma MLX IDs appear in tier-2 but not autotune (split-brain risk).

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Artifact lists all 7 live recommendable keys + hashes; no orphan tier-2-only rows without explanation |
| **YELLOW** | Tier-2 unreachable but autotune verified — WAIVED for catalog add with “tier-2 pending” note |
| **RED** | Hash mismatch between deployed provider snapshot and tier-2 for a **live** model — fix before new publishes |

### Artifacts

- `beta/catalog-expansion/P0-02-tier2-catalog-snapshot.md` — redacted snapshot table (no secrets)

---

## P0-03 — HuggingFace MLX weight availability (flagship candidates)

| Field | Value |
|-------|-------|
| **ID** | `P0-03` |
| **Question** | Do MLX-ready quantized weights exist for **`gpt-oss-120b`**, **`gemma-4-31b-4bit`**, **`qwen3-next-80b-a3b`**? |
| **Prerequisites** | Network read to huggingface.co / mlx-community |

### Procedure

1. For each target, search `mlx-community/*` repos (and `lmstudio-community/*` as fallback).
2. Record per repo: revision, total `*.safetensors` size, `config.json` → `model_type`, license.
3. Cross-check `model_type` against `LLMTypeRegistry` (`LLMModelFactory.swift:26–87`).
4. Flag repos with weights but **wrong/missing `model_type`** (needs-arch-work despite files).

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | ≥1 repo per target with matching `model_type` and size estimate |
| **YELLOW** | Weights exist but `model_type` unverified or community-only — OK for P4 bench only |
| **RED** | No MLX weights found — remove from P4 until weights exist |

### Artifacts

- `beta/catalog-expansion/P0-03-hf-weights-audit.md`

---

## P0-04 — Gemma-4 chat template / OpenAI API compatibility

| Field | Value |
|-------|-------|
| **ID** | `P0-04` |
| **Question** | Does Gemma-4 produce correct chat completions through MacProvider’s OpenAI-compatible path after `mlx-swift-lm` 3.x migration? |
| **Prerequisites** | P0-01 not RED; local model snapshot or HF download |

### Procedure

1. Load `mlx-community/gemma-4-26b-a4b-it-4bit` via `macprovider-cli serve` (or Malibu agent path).
2. Send `POST /v1/chat/completions` with:
   - Single-turn user message
   - Multi-turn system+user+assistant
   - Tool-free JSON-style prompt (smoke)
3. Check: no template leakage (`<start_of_turn>`, raw special tokens in output), stop tokens fire, reasonable length.
4. Compare tokenizer path: `#huggingFaceTokenizerLoader()` (`ModelRuntime.swift:1887–1890`) — note any `extraEOSTokens` need per `supported-models.md` Gemma section.
5. If Darkbloom reference clone available, compare **behavioral** (not source) output shape only on same prompt — optional.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Clean assistant text, stable stops, no crash on 3 prompt shapes |
| **YELLOW** | Minor formatting quirks; document workaround (e.g. `extraEOSTokens`) |
| **RED** | Garbled output, crash, or empty completions — **blocks P1** until template fix |

### Artifacts

- `beta/catalog-expansion/P0-04-gemma4-template-probe.md` — request/response samples (truncated)

---

## P0-05 — Nemotron-3-Nano `model_type` in config.json

| Field | Value |
|-------|-------|
| **ID** | `P0-05` |
| **Question** | Which `model_type` does `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` declare, and does `LLMTypeRegistry` cover it? |
| **Prerequisites** | HF repo metadata or local snapshot from live catalog revision `832f602e…` |

### Procedure

1. Read `config.json` from HF repo at catalog revision (`autotune-candidates.json` nemotron row).
2. Confirm `LLMTypeRegistry.shared.contains(modelType)` — registry at `LLMModelFactory.swift:26–87`; candidate types: `nemotron_h`, `afmoe`, `qwen3_moe`, etc.
3. If live serve already works (catalog says “runtime validated”), document observed load path as evidence.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | `model_type` identified and registered; load succeeds |
| **RED** | `unsupportedModelType` at load — catalog row is falsely “recommendable”; hotfix required |

### Artifacts

- `beta/catalog-expansion/P0-05-nemotron-model-type.md`

---

## P0-06 — Tier-2 catalog republish (remediation from P0-02 RED)

| Field | Value |
|-------|-------|
| **ID** | `P0-06` |
| **Trigger** | P0-02 RED |
| **Goal** | Bring production tier-2 (`macprovider-tier2-model-catalog-2026-05-31`) in line with live autotune `published-2026-07-06-mbase-lite` |
| **Prerequisites** | Operator signing key; `scripts/sign-catalog.go`; Pearl deploy access |

### Procedure

1. Build new tier-2 manifest with **all 7** live recommendable `model_id` + `sha256` + `min_ram_gb` from `autotune-candidates.json`.
2. **Remove or deprecate** legacy tier-2-only rows: `Qwen2.5-7B`, `Qwen2.5-Coder-7B` (unless operator explicitly keeps as non-autotune aliases).
3. Fix **Llama-3.2-3B** hash: autotune `3975387f…7216a` (rev `7f0dc925`) replaces tier-2 `0baf1371…fe2fe`.
4. Sign with Ed25519 (`sign-catalog.go`); deploy to `/opt/macprovider/tier2-catalog.json`; verify `GET /catalog/current` returns new `catalog_id` + issued_at.
5. Re-run **P0-02** → target GREEN.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | P0-02 re-run GREEN; 7/7 autotune models in tier-2 with matching SHA |
| **RED** | Deploy or signature failure |

### Artifacts

- `beta/catalog-expansion/P0-06-tier2-republish.md` — new catalog_id, deploy timestamp, P0-02 re-run link

**Blocks:** P1-03, P2 publishes, G2.

---

## P0 rollup — `P0_SUMMARY.md`

Executor agent after P0-01..05:

1. Write `beta/catalog-expansion/P0_SUMMARY.md` with gate table (GREEN/YELLOW/RED per task).
2. Recommend **G0: PROCEED / HOLD / WAIVE-list**.
3. Post summary to pinned session for sign-off.

**Pinned session action:** Update Status tracker; bump plan version if gates change.

---

# P1 — Unblock Gemma-4-26B-A4B (highest leverage)

> **Goal:** Move `google-gemma-4-26b-a4b-it` from `blocked` → `recommendable`; Darkbloom + OpenRouter parity.  
> **Requires:** G0 PROCEED; P0-01 not RED; P0-04 not RED.

---

## P1-01 — Hardware bench matrix

| Field | Value |
|-------|-------|
| **ID** | `P1-01` |
| **Machines** | 32 GB (M-Base, required) + 48 GB (M-Pro, optional) — minimum **1 clean run on 32 GB** |
| **Tooling** | Stage1 probe path (`Stage1Iterator.swift:379–537`) or `macprovider-cli autotune` — **not** ad-hoc single-shot scripts |

### Contamination caveat (from P0-01 — pinned session 2026-07-07)

P0-01 **GREEN stands for memory** (~15 GB resident, 32 GB load PASS) but its **~7.7 tok/s Gemma TPS is low-confidence** and must **not** be used to set catalog `min_sustained_tps`.

| P0-01 issue | Impact |
|-------------|--------|
| Dev provider (`qwen3-coder-30b` on port 61919) running alongside bench | Possible GPU/CPU contention |
| gpt-oss control ~9–11 tok/s vs catalog anchor **~16.7 tok/s** on M5 (`autotune-candidates.json` notes) | Environment or probe-shape mismatch — **depressed TPS likely** |
| Single rough sample, 64 decode tokens after 4K prefill | Not comparable to Stage1 **median** sustained TPS |
| No CPU/thermal/process snapshot recorded | Cannot rule out background load |

**P1-01 must produce fresh TPS under a clean machine protocol below.**

### Environment prep (mandatory before any TPS number)

1. **Quit all other `macprovider-cli serve` instances** (including dev providers on alternate ports).
2. **Quit heavy apps** (browsers, other agents, node servers on inference ports).
3. Record **before each run**:
   - `memory_pressure` one-liner
   - `ps aux \| head` or process count of `macprovider-cli`
   - Chip + RAM GB + power mode if not on AC
4. Prefer **release build** (`phase3-binary/.build/release/macprovider-cli`) per P0-01/P0-04.
5. **Reboot optional** but recommended if prior session loaded large models (memory fragmentation).

### gpt-oss sanity check (gate before locking Gemma bench gates)

On the **same 32 GB machine**, before or interleaved with Gemma benches:

1. Run Stage1/autotune probe on **`mlx-community/gpt-oss-20b-MXFP4-Q8`** (live catalog control).
2. Compare **median sustained TPS** to published anchor: catalog notes cite **~16.7 tok/s** cold-start on M5; live `min_sustained_tps: 15` (`autotune-candidates.json`).
3. **Sanity PASS:** gpt-oss median TPS ≥ **12** (≥75% of catalog 15 gate) on clean machine.
4. **Sanity FAIL:** gpt-oss still <12 → **fix environment and re-run**; do not publish Gemma `min_sustained_tps` until sanity PASS.

Document sanity result in artifact § "Environment sanity check".

### Procedure

1. Confirm **gpt-oss sanity PASS** (above).
2. Bench **`mlx-community/gemma-4-26b-a4b-it-4bit`**: **median** TPS, p95 4K TTFT via Stage1/autotune (≥3 probe iterations if manual).
3. On 32 GB: confirm no OOM/swap; cross-check P0-01 resident ~15 GB if memory logged.
4. Optional 48 GB tier for headroom / concurrency signal.
5. Set proposed Gemma `min_sustained_tps` as **advisory** — typically **≤ gpt-oss median on same box** or ~75% of measured Gemma median (same pattern as gpt-oss 30→15 M-Base downgrade). **Do not copy P0-01 ~7.7.**
6. Proposed `min_ram_gb`: **28** from P0-01 (memory-based); operator may choose 32 conservative.
7. Record `ModelFit.evaluate` for awareness only — **do not derive gates from ModelFit** for MoE (`P0-01`).

### Pass / fail (G1)

| Result | Criteria |
|--------|----------|
| **PASS** | gpt-oss sanity PASS + Gemma median TPS documented on clean 32 GB + no OOM; proposed gates justified vs measured medians |
| **FAIL** | gpt-oss sanity FAIL (environment) OR Gemma OOM on 32 GB OR cannot reproduce load after 3 attempts |

### Artifacts

- `beta/catalog-expansion/P1-gemma4-bench-matrix.md` — must include: environment snapshot, gpt-oss sanity table, Gemma median TPS, proposed `min_sustained_tps` / `min_ram_gb`, explicit statement that P0-01 ~7.7 was superseded

---

## P1-02 — Rate card + pricing row

| Field | Value |
|-------|-------|
| **ID** | `P1-02` |
| **Prerequisites** | P1-01 PASS; operator pricing target |
| **Files** | `phase4-coordinator/dist/coordinator.yaml` rewards.rate_card; `scripts/sign-catalog.go` rate card signing if applicable |

### Procedure

1. Add `google-gemma-4-26b-a4b-it` (or normalized key per `billing/formula.go:65–88`) to rate card.
2. Anchor to RESEARCH_226 / Darkbloom live (~$0.33/M OR market undercut — operator choice).
3. Document prompt/completion credits in artifact; **do not deploy** until P1-03 signed.

### Artifacts

- Section in `P1-gemma4-catalog-rollout.md` (pricing table)

---

## P1-03 — Catalog + tier-2 + static publish

| Field | Value |
|-------|-------|
| **ID** | `P1-03` |
| **Prerequisites** | P1-01 PASS, P1-02 approved, P0-02 GREEN |
| **Touch list** | `phase3-binary/dist/static/autotune-candidates.json`, `demand-rank.json`, baked fallback `AutotuneRecommend.swift:1934–1935`, tier-2 catalog, coordinator static deploy |

### Procedure

1. Add live row:
   - `model_id`: `mlx-community/gemma-4-26b-a4b-it-4bit` (or QAT variant if P0-01 favors it)
   - `min_ram_gb`: from P1-01 (likely 28–32)
   - `min_bandwidth_tier`: `C` or `B` from bench
   - `runtime_status`: `recommendable`
   - `model_revision`, `model_sha256`: from HF snapshot
2. Remove `blocked` from baked fallback; align baked/live.
3. Add demand-rank row (`demand_weight` ~0.5–0.6; RESEARCH_226 rank ~22).
4. Compute SHA-256 manifest hash; sign tier-2 entry (`tier2/catalog.go`, `sign-catalog.go`).
5. Re-sign autotune static v4 Ed25519 (`AutotuneRecommend.swift:684–687`).
6. Run tests: `AutotuneRecommendSimulateTests`, billing route snapshot tests.

### Pass / fail (G2)

| Result | Criteria |
|--------|----------|
| **PASS** | Static JSON live; tier-2 hash verifies; autotune recommends Gemma on eligible hardware |
| **FAIL** | Signature, hash, or simulate test failure |

### Artifacts

- `beta/catalog-expansion/P1-gemma4-catalog-rollout.md` — PR link, catalog version string, deploy checklist

---

## P1-04 — Optional QAT variant follow-up

| Field | Value |
|-------|-------|
| **ID** | `P1-04` |
| **When** | After P1-03 stable OR if P0-01 shows QAT fits 24 GB better |
| **Model** | `gemma-4-26b-qat-4bit` (Darkbloom prod id pattern) |

Separate catalog key or quant suffix — operator decision. Lower priority than P1-03 text-only 4bit.

---

# P2 — Cheap catalog wins (parallel after G1)

> **Goal:** Widen supply without engine changes.  
> **Requires:** G2 for coordination deploy; can prep PRs during P1.  
> **Execution order (2026-07-07):** P2-03 → P2-02 → P2-01 deferred (weak demand vs existing coder/Nemotron/Gemma rows).

---

## P2-01 — Qwen3-30B-A3B general (non-coder)

| Field | Value |
|-------|-------|
| **ID** | `P2-01` |
| **MLX ID** | `mlx-community/Qwen3-30B-A3B-4bit` (verify HF name in P0-03 style) |
| **Catalog key** | `qwen3-30b-a3b` |
| **Basis** | Coder row `qwen3-coder-30b-a3b-instruct` (`autotune-candidates.json`) — clone gates |

### Tasks

1. Bench on 28–32 GB (expect similar to coder MoE).
2. Add rate card row (RESEARCH_227 lane).
3. Publish autotune + tier-2 + demand-rank.

**Effort:** trivial variant.

---

## P2-02 — Small-tier dense (pick one or both)

| Field | Value |
|-------|-------|
| **ID** | `P2-02` |
| **Candidates** | `mlx-community/Qwen3-8B-4bit`, `mlx-community/Qwen2.5-7B-Instruct-4bit`, `SmolLM3` if weights found |
| **Target tier** | 12–16 GB (`min_ram_gb` 8–12) |
| **Rationale** | Only `llama-3.1-8b` + `llama-3.2-3b` serve small tier today |

### Tasks

1. Stage1 bench on 16 GB Mac.
2. Rate card: match small-dense lane (`llama-3.1-8b` pricing in `coordinator.yaml:179–186`).
3. Publish catalog rows.

---

## P2-03 — Baked/live drift cleanup

| Field | Value |
|-------|-------|
| **ID** | `P2-03` |
| **Issue** | Baked fallback drift vs live/coordinator (post-P1): `bakedRateCardJSON` still `baked-2026-07-03` — Nemotron credits wrong (235k vs 160k live), Gemma rows present in baked catalog but verify byte parity; candidate/demand should mirror `published-2026-07-07-p1-gemma` |

Align all three baked strings (`bakedCandidateCatalogJSON`, `bakedDemandRankJSON`, `bakedRateCardJSON`) with live static + `coordinator.yaml` rate card. **No new catalog version** unless drift fix requires re-sign (rate-card-only fix = Swift baked string only).

---

# P3-R231 — RESEARCH_231 gate calibration (executor-scoped)

> **Goal:** Act on [`docs/research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md`](../research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md) Part 3 deltas **without** attempting impossible benches on the M5 32 GB executor.  
> **Input:** oMLX advisory data + existing local benches (P1-01, P2-02).  
> **Requires:** G3 closed (current catalog `published-2026-07-07-p2-qwen3-8b`).

## P3-R231-00 — Executor scope lock (do first)

| Field | Value |
|-------|-------|
| **ID** | `P3-R231-00` |
| **Action** | Record executor limits in artifact; **no load/bench** on BLOCKED rows |
| **Artifact** | `beta/catalog-expansion/P3-r231-gate-calibration.md` § Executor scope |

**BLOCKED on M5 32 GB executor (do not probe):**

| Memo item | Why blocked on executor |
|-----------|-------------------------|
| **P1 new row `qwen3.6-35b-a3b`** | ~20.4 GB weights; VLM pin (`vision_config`); tier **B** gate; needs **M4 Max 48 GB+** + text-only MLX pin on proper HW |
| **P0 gate `qwen3-32b` 15→10** | FB-02 requires **M4 Pro 48 GB**; dense ~19 GB resident |
| **P1 gate `qwen2.5-coder-32b` 20→15** | FB-03 requires **M4 Max 64 GB** |
| **P0 gate `nemotron-3-nano` 30→20** | FB-01 not run; 30B MoE at catalog `min_ram_gb: 32` — no local repro on executor; oMLX-only |
| **FB-04..FB-05** | Wrong hardware class entirely |

**Permitted on executor (already done — hold):**

| Memo item | Local evidence |
|-----------|----------------|
| `gpt-oss-20b`, `gemma-4-26b-a4b-it`, `qwen3-8b` gates | P1-01 / P2-02 — **keep** |

### Pass / fail

| Result | Criteria |
|--------|----------|
| **PASS** | Artifact lists BLOCKED vs OK rows; no improbable bench attempted on executor |
| **FAIL** | Any `autotune`/`serve` run on a BLOCKED row from the table above |

---

## P3-R231-01 — Advisory-only gate memo (no catalog PR)

| Field | Value |
|-------|-------|
| **ID** | `P3-R231-01` |
| **Prerequisites** | P3-R231-00 PASS |
| **Deliverable** | Ranked gate deltas tagged `oMLX-only / blocked-local` — **no** `autotune-candidates.json` edit |

### Procedure

1. Copy RESEARCH_231 Part 3 P0/P1 items into artifact with columns: `local_bench_status`, `required_hardware`, `executor_eligible`.
2. Mark every P0/P1 delta without local repro as **`DEFERRED — needs off-executor HW`**.
3. Do **not** open a catalog PR from oMLX-only evidence while executor cannot falsify.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **PASS** | Operator has a single deferred queue keyed to hardware tier |
| **FAIL** | Catalog JSON changed without local bench on eligible executor or off-executor HW |

---

## P3-R231-02 — Off-executor bench queue (future)

| Field | Value |
|-------|-------|
| **ID** | `P3-R231-02` |
| **Status** | **`BLOCKED`** until M4 Pro 48 GB+ or M4 Max 64 GB+ machine available |
| **Tasks** | FB-02, FB-03, FB-04 (nemotron FB-01 deferred — oMLX-only until assigned HW) |

When hardware appears, repeat **P1-01 clean-machine protocol** on the **target tier machine only**. Do not substitute M5 32 GB results for Tier-B/A gate proposals.

---

# P3 — VLM decision (planning only in this runbook)

> **Goal:** Go/no-go on multimodal before any engine sprint.  
> **Does not require** G2; requires operator input.

---

## P3-01 — Decision record

| Field | Value |
|-------|-------|
| **ID** | `P3-01` |
| **Output** | `beta/catalog-expansion/P3-vlm-decision.md` |

### Questions to answer

1. Is multimodal required for competitive parity with Darkbloom Gemma-4 VLM in **2026 Q3**?
2. If yes: first VLM target — **Gemma-4 VLM** (`VLMTypeRegistry` `gemma4`, `VLMModelFactory.swift:98–99`) vs **Qwen2.5-VL-3B** (smaller scope)?
3. API shape: image in `/v1/chat/completions` messages vs separate endpoint?
4. Accept engine work: integrate `VLMModelFactory` into `ModelRuntime` (today **LLM-only**, `ModelRuntime.swift:1887`).

### Outcomes

| Decision | Next work (out of this runbook) |
|----------|--------------------------------|
| **VLM yes** | Spawn `BUILD_SPEC_VLM_ENGINE.md` — estimated multi-week |
| **VLM no** | Defer P3 engine; text-only depth through P4 |

**Gate G4:** P3-01 signed by operator.

---

# P4 — Flagship tier (Tier-A hardware)

> **Goal:** Evidence before catalog commits for 64 GB+ MoE flagships.  
> **Requires:** G0; P0-03 GREEN for targets; physical Tier-A box.

---

## P4-01 — Bench `gpt-oss-120b`

| Field | Value |
|-------|-------|
| **ID** | `P4-01` |
| **Arch** | `gpt_oss` (Y) |
| **Est. resident** | 60–70 GB 4bit (RESEARCH_226) |
| **Min machine** | M4 Max 64 GB or M3 Ultra 96 GB |

Document TPS, OOM boundary, KV at 4K/8K. **No catalog row** unless PASS on ≥1 production-class Tier-A machine.

---

## P4-02 — Bench `qwen3-next-80b-a3b`

| Field | Value |
|-------|-------|
| **ID** | `P4-02` |
| **Arch** | `qwen3_next` (Y) |
| **Est. resident** | 40–45 GB 4bit |

Same procedure as P4-01.

---

## P4-03 — Optional `gemma-4-31b` dense

| Field | Value |
|-------|-------|
| **ID** | `P4-03` |
| **When** | P0-03 confirms weights + P1 Gemma-4 stable |
| **Tier** | 48 GB |

Lower priority than P4-01/02 unless OpenRouter demand priority shifts.

**Gate G5:** P4-01 or P4-02 PASS → operator approves flagship catalog PR.

---

# P5 — Explicit deferrals (no tasks until arch/weights land)

| Item | Revisit when |
|------|----------------|
| DeepSeek-V4 | `deepseek_v4` appears in `LLMTypeRegistry` |
| Llama 4 | `llama4` registered in mlx-swift-lm pin |
| MiniMax-M2.7 / Qwen3-235B | Tier-S fleet (192 GB+) exists |
| Multi-model co-residency | Product asks concurrent full-size models; needs scheduler design |
| Mixtral-8x22B, DBRX | Never unless demand recovers |

---

# Executor agent prompt template

Paste into a **new** Cursor agent session (one per task):

```
You are executing task {TASK_ID} from the MacProvider catalog expansion runbook.

Read: specs/PLAN_MODEL_CATALOG_EXPANSION_RUNBOOK.md § {TASK_ID}
Rules: CLAUDE.md worktree isolation; read-only unless task requires catalog/code changes.
Hardware: Read § Executor hardware profile FIRST — do not bench models that fail rules E1–E4.
Deliver: artifacts listed in task section under beta/catalog-expansion/
Do NOT update this plan unless asked — post artifact paths and PASS/FAIL for pinned session.
```

---

# Status tracker

> **Maintained by:** executor agents + pinned planning session.  
> Last updated: 2026-07-09 (P3-R231 scoped — executor bench envelope locked)

| Task ID | Phase | Status | Gate | Artifact | Notes |
|---------|-------|--------|------|----------|-------|
| P0-01 | P0 | **`GREEN`** | G0 | `beta/catalog-expansion/P0-01-moe-memory-parity.md` | 32 GB M5: Gemma-4 ~15 GB resident; suggest `min_ram_gb: 28` |
| P0-02 | P0 | **`GREEN`** (rerun) | G0 | `P0-02-tier2-catalog-snapshot-rerun.md` | Initial RED; fixed by P0-06 |
| P0-03 | P0 | **`GREEN`** | G0 | `beta/catalog-expansion/P0-03-hf-weights-audit.md` | Flagship HF weights confirmed |
| P0-04 | P0 | **`GREEN`** | G0 | `beta/catalog-expansion/P0-04-gemma4-template-probe.md` | Chat API clean; streaming OK; no template fix needed |
| P0-05 | P0 | **`GREEN`** | G0 | `beta/catalog-expansion/P0-05-nemotron-model-type.md` | `nemotron_h` registry match |
| P0-06 | P0 | **`GREEN`** | G2 | `beta/catalog-expansion/P0-06-tier2-republish.md` | Tier-2 `2026-07-07` live |
| P0 rollup | P0 | **`DONE`** | **G0** | `beta/catalog-expansion/P0_SUMMARY.md` | **G0 PROCEED** |
| P1-01 | P1 | **`PASS`** | G1 | `beta/catalog-expansion/P1-gemma4-bench-matrix.md` | Clean M5: gpt-oss 18.3 TPS sanity; Gemma **12.5** median (supersedes P0-01 7.7); gates `min_sustained_tps:10`, `min_ram_gb:28` |
| P1-02 | P1 | **`DONE`** | G2 | `beta/catalog-expansion/P1-gemma4-catalog-rollout.md` | Rate card $0.240/M + alias; merged #461 |
| P1-03 | P1 | **`PASS`** | G2 | `beta/catalog-expansion/P1-gemma4-catalog-rollout.md` | `published-2026-07-07-p1-gemma` live; 8 models; prod + #461 |
| P1-04 | P1 | `READY` | — | — | Optional QAT variant; after P1 soak |
| P1 rollup | P1 | **`DONE`** | **G2** | `beta/catalog-expansion/P1-gemma4-catalog-rollout.md` | **G2 CLOSED** |
| P2-01 | P2 | `DEFERRED` | G3 | — | Weak demand vs `qwen3-coder-30b` + Nemotron; RESEARCH_227 demote |
| P2-02 | P2 | **`PASS`** | G3 | `beta/catalog-expansion/P2-small-tier-catalog.md` | `qwen3-8b` 9th model; `published-2026-07-07-p2-qwen3-8b`; #466 merged; prod verified 9 rows 2026-07-07 |
| P2-03 | P2 | **`DONE`** | G3 | `beta/catalog-expansion/P2-baked-live-drift.md` | Nemotron baked rate-card drift; merged #464 |
| P2 rollup | P2 | **`CLOSED`** | **G3** | `P2-small-tier-catalog.md` | P2-02 + P2-03 complete; P2-01 deferred; prod feed-path fix applied (see note) |
| P3-R231-00 | P3-R231 | **`PASS`** | G6 | `beta/catalog-expansion/P3-r231-gate-calibration.md` | Executor scope locked 2026-07-09; no improbable benches |
| P3-R231-01 | P3-R231 | **`PASS`** | G6 | `beta/catalog-expansion/P3-r231-gate-calibration.md` | oMLX gate deltas deferred — off-executor HW required |
| P3-R231-02 | P3-R231 | **`BLOCKED`** | G6 | — | Needs M4 Pro 48 GB+ / M4 Max 64 GB+ |
| P3-01 | P3 | `PENDING` | G4 | — | Operator decision |
| P4-01 | P4 | `BLOCKED` | G5 | — | P0-03 GREEN; needs Tier-A HW bench |
| P4-02 | P4 | `BLOCKED` | G5 | — | P0-03 GREEN; needs Tier-A HW bench |
| P4-03 | P4 | `BLOCKED` | G5 | — | P0-03 GREEN (`gemma-4-31b-it-4bit` 18.4 GB); needs P1 stable + 48 GB bench |

### Gate summary

| Gate | Status | Signed off |
|------|--------|------------|
| G0 | **`CLOSED — PROCEED`** | 2026-07-07 |
| G1 | **`PASS`** (32 GB only; 48 GB tier deferred) | 2026-07-07 |
| G2 | **`CLOSED — PASS`** — Gemma-4 prod recommendable; #461 merged | 2026-07-07 |
| G3 | **`CLOSED — WAIVED`** (pre-beta; 48h soak non-informative; prod verified 9-model feed 2026-07-07) | 2026-07-07 |
| G4 | `OPEN` | — |
| G5 | `OPEN` | — |
| G6 | **`CLOSED — executor scope locked`** | 2026-07-09 — RESEARCH_231 catalog PRs blocked until off-executor HW |

### Prod deploy note (P2-02 feed-path remediation, 2026-07-07)

P2-02 executor SCP'd signed static feeds to `/opt/macprovider/static/`, but the coordinator buyer mux reads **`/opt/macprovider/autotune/`** (`coordinator.yaml` `autotune.*_path`). Tier-2 at `/opt/macprovider/tier2-catalog.json` was already correct; only autotune feeds were stale (7-row `published-2026-07-06-mbase-lite` served publicly).

**Fix:** copy `static/` → `autotune/` on Pearl, then **restart** coordinator (autotune paths are startup-only; SIGHUP reloads tier-2/rate-card but not feeds). Verified: `/v1/autotune-candidates` → `published-2026-07-07-p2-qwen3-8b`, 9 rows; `/catalog/current` → 9 models.

**Future publishes:** use `deploy-pearl-vps.sh` (installs to `/opt/macprovider/autotune/`) or SCP directly to `autotune/`, not `static/`.

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 0.1 | 2026-07-07 | Initial runbook from catalog expansion exploration §9–10 |
| 0.1.1 | 2026-07-07 | P0-05 GREEN — nemotron_h registry confirmed |
| 0.1.2 | 2026-07-07 | P0-02 RED — tier-2/autotune split-brain; added P0-06 remediation |
| 0.1.3 | 2026-07-07 | P0-03 GREEN — flagship HF weights confirmed for P4 |
| 0.1.4 | 2026-07-07 | P0-06 GREEN + P0-02 rerun GREEN — tier-2 `2026-07-07` live, 7/7 aligned |
| 0.1.5 | 2026-07-07 | P0-01 GREEN — Gemma-4 ~15 GB on 32 GB M5; P0-04 + P1-01 unblocked |
| 0.1.6 | 2026-07-07 | P0-04 GREEN + G0 CLOSED — `P0_SUMMARY.md`; P1-01 unblocked |
| 0.1.7 | 2026-07-07 | P1-01: P0-01 TPS contamination caveat + mandatory gpt-oss sanity check |
| 0.1.8 | 2026-07-07 | P1-01 PASS — Gemma 12.5 TPS / gates 10+28; gpt-oss sanity 18.3 |
| 0.1.9 | 2026-07-07 | P1 DONE + G2 CLOSED — commit P0/P1 artifacts; #461 merged |
| 0.1.10 | 2026-07-07 | G3 WAIVED pre-beta; P2 unblocked; P2-03 → P2-02 order; P2-01 deferred |
| 0.1.11 | 2026-07-07 | P2-03 DONE (#464); P2-02 PASS — `qwen3-8b` small-tier live |
| 0.1.12 | 2026-07-07 | P2/G3 CLOSED — prod feed-path fix (`static/` → `autotune/` + restart); runbook PARKED |
| 0.1.13 | 2026-07-09 | Executor hardware profile + P3-R231: RESEARCH_231 gate/new-row work BLOCKED on M5 32 GB; no improbable benches |
