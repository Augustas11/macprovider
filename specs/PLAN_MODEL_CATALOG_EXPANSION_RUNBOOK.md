# PLAN — Model Catalog Expansion Runbook

**Version:** 0.1.9  
**Date:** 2026-07-07  
**Status:** ACTIVE — execution plan (not normative spec)  
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
  P4-flagship-bench.md
```

---

## Decision gates (master)

| Gate | Requires | Blocks |
|------|----------|--------|
| **G0** | All P0 tasks GREEN or WAIVED | P1 runtime bench |
| **G1** | P1 bench PASS on ≥2 RAM tiers | Gemma-4 catalog publish |
| **G2** | G1 + rate-card + tier-2 hash signed | Prod recommendable |
| **G3** | P2 artifacts + G2 stable 48h | Small-tier publish |
| **G4** | P3 decision record (VLM yes/no) | Any VLM engine work |
| **G5** | P4 bench on Tier-A hardware | Flagship catalog rows |

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

1. Fetch live autotune catalog: `https://coordinator.streamvc.live/static/autotune-candidates.json` (see `AutotuneRecommend.swift:749`).
2. Obtain production tier-2 catalog:
   - **Preferred:** read-only from Pearl VPS `/opt/macprovider/tier2-catalog.json` (`coordinator.yaml:202`), OR
   - `GET https://coordinator.streamvc.live/catalog/current` / pubkey endpoints per `buyer/server.go`.
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
| **Issue** | Baked fallback diverges from live on `qwen3-32b` min_ram (32 vs 48), `qwen2.5-coder` (64 vs 48) per `AutotuneRecommend.swift:1913–1929` |

Align baked JSON with live after P1/P2 publishes to avoid offline autotune surprises.

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
Deliver: artifacts listed in task section under beta/catalog-expansion/
Do NOT update this plan unless asked — post artifact paths and PASS/FAIL for pinned session.
```

---

# Status tracker

> **Maintained by:** executor agents + pinned planning session.  
> Last updated: 2026-07-07 (P1 DONE, G2 CLOSED — #461 merged)

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
| P2-01 | P2 | `BLOCKED` | G3 | — | Needs G2 stable 48h |
| P2-02 | P2 | `BLOCKED` | G3 | — | Needs G2 stable 48h |
| P2-03 | P2 | `BLOCKED` | G3 | — | Baked/live drift |
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
| G3 | `OPEN` — needs G2 stable 48h | — |
| G4 | `OPEN` | — |
| G5 | `OPEN` | — |

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
