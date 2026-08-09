# PLAN — MacProvider Throughput Engineering Runbook

**Version:** 0.1.10  
**Date:** 2026-07-07  
**Status:** ACTIVE — **T0–T3 merged** (TG0/TG3 closed); upstream watch (#364, #406) or operator T4-01  
**Source analysis:** Throughput engineering exploration (2026-07-07 Cursor session)  
**Pinned session role:** Single plan-of-record for MLX/engine/egress throughput work. Executor agents update task status here; the pinned planning session verifies gates and revises sequencing.

**Relationship to other plans**

| Plan | Overlap |
|------|---------|
| `specs/PLAN_MODEL_CATALOG_EXPANSION_RUNBOOK.md` | P1 Gemma catalog gates (`min_sustained_tps`) depend on **T1-02** bench truth; do not publish new MoE rows on P0-01–contaminated numbers |
| `specs/perf-mlx-compile-bf16-upgrade.md` | Superseded for pin strategy — we now target **`mlx-swift-lm` exact pin** (not legacy `mlx-swift-examples`). Reuse Phase 2 bench methodology only |
| `audits/2026-06-30/perf-mlx-engine.md` | Prior `decode-bench` / `CompiledDecode.swift` on branch `perf/mlx-compile-bf16` — **not merged**; T0-01 may cherry-pick |

---

## How to run this plan

1. **Pinned session:** approve phase transitions, resolve gate conflicts with catalog runbook, update version/status in this file.
2. **Executor agents:** one agent per task ID. Each agent:
   - Works in a **fresh worktree** off `origin/main` (`CLAUDE.md` § worktree isolation).
   - Reads only its task section + prerequisites.
   - Produces listed **Artifacts** under `beta/throughput-engineering/`.
   - Runs the **audit loop** (code + security + architect) before marking implementation tasks GREEN.
   - Posts artifact paths + PASS/FAIL; does **not** edit this plan unless asked.
3. **Do not skip T0.** Phases T1–T3 assume measurement harness and baseline JSON exist.
4. **Clean-room:** use only Macprovider and upstream `ml-explore` sources. Do
   **not** inspect Darkbloom, Layr-Labs forks, or `d-inference` source.

### Artifact layout

```
beta/throughput-engineering/
  T0_SUMMARY.md                      # rollup after T0-01..03
  T0-01-decode-bench-harness.md
  T0-02-baseline-matrix.json         # committed snapshot copies under audits/
  T0-03-egress-profile.md
  T1-01-mlx-pin-bump.md
  T1-02-gemma-moe-decode-delta.md
  T1-03-metallib-rebuild.md
  T2-01-compiled-decode-wire-in.md
  T2-02-decode-bandwidth-model.md
  T3-01-stream-interval.md
  T3-02-adaptive-prefill-spike.md
  T3-03-kv-quant-scheme.md
  T4-01-cbv2-feasibility.md          # architecture spike only until GO
  T4-02-cbv2-impl.md                 # if T4-01 GO
  DEFERRED.md                        # explicit non-adopts (NWConnection cluster)
```

---

## Decision gates (master)

| Gate | Requires | Blocks |
|------|----------|--------|
| **TG0** | T0 harness + baseline JSON on reference Mac | Any perf PR merge |
| **TG1** | T1 pin bump GREEN + token-exact regression | Compiled decode wire-in (T2) |
| **TG2** | T2 compiled decode GREEN on Gemma-4 + gpt-oss | Catalog TPS gate raises |
| **TG3** | T3 provider opts measured ≥3% win OR explicit WAIVE | Prod config defaults change |
| **TG4** | T4-01 feasibility GO + operator sign-off | Engine V2 / CBv2 port (T4-02) |

---

## Priority stack (from exploration ranked recommendations)

| Rank | Work item | Phase | Bucket | Expected lever |
|------|-----------|-------|--------|----------------|
| 1 | MLX 0.32.0 + `mlx-swift-lm` bump (#474, #470, #481, #516) | T1 | A | Single-stream TPS; MoE sparsity |
| 2 | Compiled MoE decode opt-in (#482+#516 pair) | T2 | A | +15–25% MoE decode (**measure**) |
| 3 | Continuous batching / Engine V2 (#499) | T4 | A+B | Aggregate multi-stream TPS |
| 4 | Adaptive prefill (#466) | T3 | B | TTFT on long prompts |
| 5 | `streamInterval`≈4 token batching | T3 | B | Egress CPU; minor TPS |
| 6 | KV quant family scheme | T3 | B | Concurrency / long context |
| — | NWConnection / ChunkBatcher (#479–#476) | DEFER | C | **Do not implement** unless T0-03 proves egress bound |

---

# T0 — Measurement foundation (run first)

> **Goal:** Every later claim is measured, not assumed. No submodule bumps before TG0.

---

## T0-01 — Restore `decode-bench` harness on `main`

| Field | Value |
|-------|-------|
| **ID** | `T0-01` |
| **Question** | Can we run **pure decode** benchmarks (no coordinator, no WS) on `main`? |
| **Prerequisites** | Release build + bundled metallib (`phase3-binary/dist/package.sh`) |
| **Branch** | `perf/decode-bench-harness` |

### Procedure

1. Cherry-pick or re-port from `perf/mlx-compile-bf16` (see `audits/2026-06-30/perf-mlx-engine.md`):
   - `DecodeBenchCommand.swift`
   - `MacProviderCLI.swift` subcommand registration
   - Tests in `WeightCastTests.swift` only if `WeightCast` also lands (optional)
2. **Do not** wire `CompiledDecode` or bf16 cast in this task — harness only.
3. CLI shape:
   ```bash
   macprovider-cli decode-bench \
     --model <mlx-repo-id> \
     --prefill-tokens 512 \
     --decode-tokens 256 \
     --runs 5 \
     --output state/perf/baseline-<tag>.json
   ```
4. Document generation-only TPS semantics (match `Stage1Iterator.swift:606-623` — denominator excludes TTFT).
5. Run audit loop on the harness PR.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Subcommand runs on M-series; writes JSON; `swift test` green |
| **RED** | Cannot load model or metallib missing in release — fix packaging first (`T1-03` dependency) |

### Artifacts

- `beta/throughput-engineering/T0-01-decode-bench-harness.md`
- `audits/2026-07-07/decode-bench-harness/` — sample JSON snapshot

---

## T0-02 — Baseline matrix (reference hardware)

| Field | Value |
|-------|-------|
| **ID** | `T0-02` |
| **Question** | What are **pinned-pin** decode TPS / TTFT numbers for catalog-critical models? |
| **Prerequisites** | T0-01 GREEN; **clean machine** (no other `serve` processes) |

### Models (minimum)

| Model | Role | Notes |
|-------|------|-------|
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | Dense control | Prior baseline ~29.2 TPS M5 (`perf-mlx-engine.md`) |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | MoE primary | Supersedes P0-01 ~7.7 TPS; target clean re-measure |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | MoE control | Catalog anchor; sanity ≥12 TPS on 32 GB M5 |

### Procedure

1. Hardware record: chip, RAM, macOS, `macprovider-cli` version, `Package.resolved` mlx pins.
2. Per model: 3+ runs, report p50 decode TPS, p50 prefill TPS, TTFT for 512 prefill / 256 decode.
3. Cross-check Gemma vs `DecodeBandwidthModel` implied active params (T0-02 may use spreadsheet; T2-02 ports the Swift module).
4. Store immutable JSON under `audits/2026-07-07/bench-snapshots/` (copy from gitignored `state/perf/`).

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | All three models complete without swap; JSON committed |
| **YELLOW** | One model fails load — document blocker; other baselines still valid |
| **RED** | Harness cannot reproduce prior Qwen baseline within 10% on same hardware — debug before T1 |

### Artifacts

- `beta/throughput-engineering/T0-02-baseline-matrix.json` (summary table + paths to snapshots)
- Update `beta/catalog-expansion/P1-gemma4-bench-matrix.md` cross-ref if numbers supersede P1-01

---

## T0-03 — Egress vs decode profile (prior finding verification)

| Field | Value |
|-------|-------|
| **ID** | `T0-03` |
| **Question** | Is `URLSessionWebSocketTask.send` ever >5% of per-token wall time at catalog TPS? |
| **Prerequisites** | Tier-2 serve path running locally OR instrumented integration test |

### Procedure

1. Add **temporary** debug timing (feature-flagged `MACPROVIDER_PERF_TRACE=1`) around:
   - `ModelRuntime` generate callback entry
   - `InferenceRelay.sendChunk` pre/post `sendFrame`
   - `CoordinatorClient.send(_:to:)` (`CoordinatorClient.swift:2427-2433`)
2. Run one streaming request at ~25–30 TPS equivalent (dense model) and ~12 TPS (Gemma).
3. Aggregate: mean/p95 µs in decode callback vs seal vs WS send.
4. **Remove or gate** trace code before merge; keep unit test that flag defaults off.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | WS send + seal <5% of token period at p95 → **NWConnection cluster remains DEFER** |
| **YELLOW** | 5–15% → T3-01 `streamInterval` promoted |
| **RED** | >15% → open reassessment of #479 (document in `DEFERRED.md` with evidence) |

### Artifacts

- `beta/throughput-engineering/T0-03-egress-profile.md`

---

## T0 rollup

Executor writes `beta/throughput-engineering/T0_SUMMARY.md` with TG0 recommendation (**PROCEED** / **HOLD**).

---

# T1 — MLX engine foundation (bucket A)

> **Goal:** Bump to MLX **0.32.0** / latest compatible **`mlx-swift-lm`** without correctness regression.  
> **Current pins:** `mlx-swift` 0.31.4, `mlx-swift-lm` 3.31.4 (`Package.resolved`). The 0.31.4 compatibility pin is required by the production Xcode 16.4 / Swift 6.1 release toolchain; performance evidence recorded against 0.31.6 remains historical and must not be silently attributed to this release.
> **Source policy:** adopt only tagged, remotely consumable **ml-explore** releases;
> no Darkbloom or Layr-Labs source inspection/fallback is permitted.

---

## T1-01 — Pin bump + build green

| Field | Value |
|-------|-------|
| **ID** | `T1-01` |
| **Question** | Does latest reachable **ml-explore** `mlx-swift-lm` (≥3.31.x) + transitive `mlx-swift` 0.32.x build and pass tests? |
| **Prerequisites** | TG0; worktree `perf/mlx-0.32-bump` |
| **Touches** | `phase3-binary/Package.swift`, `Package.resolved`, adapter fixes in `ModelRuntime.swift` if API drift |

### Procedure

1. Require a tagged, remotely consumable `mlx-swift-lm` release; upstream #518
   must be closed/released, and the resolved graph must build under protected
   Xcode 16.4 / Swift 6.1.
2. Bump the MLX pins without changing `swift-transformers`; tokenizer migration
   is owned independently by #966.
3. Run every required row in
   `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md`, including token/settlement
   parity, cache ownership/wrap, model/template coverage, metallib and immutable
   release-artifact parity.
4. Run the full audit loop (code, security, architect).
5. PR to `main`; **no** compiled-decode or config-default changes in this PR.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Every mandatory matrix row passes; no waivers |
| **BLOCKED** | No compatible tagged/package-consumable release or protected-toolchain build |
| **RED** | Any token, settlement, cache, artifact, model/template, or performance gate fails — revert pin |

### Artifacts

- `beta/throughput-engineering/T1-01-mlx-pin-bump.md`

---

## T1-02 — MoE decode delta (Gemma + gpt-oss)

| Field | Value |
|-------|-------|
| **ID** | `T1-02` |
| **Question** | How much does T1 pin bump move **MoE decode TPS** and implied sparsity? |
| **Prerequisites** | T1-01 merged |

### Procedure

1. Re-run T0-02 matrix on **post-bump** binary (same hardware).
2. Compute Δ vs T0-02 per model; for Gemma, compute implied active params using bandwidth model (hand spreadsheet OK).
3. Compare to catalog gates: `min_sustained_tps` in autotune catalog (`AutotuneRecommend.swift:996+`).
4. If Gemma median < gate after bump → **TG2 blocked** until T2-01.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Gemma median ≥ catalog gate (currently 10 TPS post-P1-01) **OR** gate explicitly revised with operator sign-off |
| **YELLOW** | Improved but below gate — proceed to T2 |
| **RED** | Regression vs T0-02 on any model >5% without explanation |

### Artifacts

- `beta/throughput-engineering/T1-02-gemma-moe-decode-delta.md`

---

## T1-03 — Metallib rebuild + artifact check

| Field | Value |
|-------|-------|
| **ID** | `T1-03` |
| **Question** | Does release packaging ship a metallib **matched** to bumped MLX? |
| **Prerequisites** | T1-01 |

### Procedure

1. Run `phase3-binary/scripts/build-mlx-metallib.sh` (or document PyPI bundle path if still valid).
2. Verify `scripts/check-tier2-provider-artifact.sh` passes on release tarball.
3. Record metallib hash in artifact doc (pattern: upstream `#472` attestation — optional follow-up for tier-2 attestation).

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Release install loads model without metallib fallback warnings |
| **RED** | Missing `default.metallib` in field installs |

### Artifacts

- `beta/throughput-engineering/T1-03-metallib-rebuild.md`

---

# T2 — Compiled decode + measurement model (bucket A)

> **Goal:** Wire `MLX.compile()` decode path for MoE catalog models; validate #482+#516 as a **pair** (no fused-cache RAM regression — P0-01 already shows clean residency on 3.31.4; re-verify post-compile).

---

## T2-01 — Compiled decode wire-in

| Field | Value |
|-------|-------|
| **ID** | `T2-01` |
| **Question** | Does opt-in compiled decode improve MoE TPS with **token-exact** greedy output? |
| **Prerequisites** | TG1; port `CompiledDecode.swift` from `perf/mlx-compile-bf16` |
| **Env flag** | `MACPROVIDER_COMPILED_DECODE=1` (default **off**) |

### Procedure

1. Port `CompiledDecode.swift` + `KVCacheUpdatableAdapter`; integrate at `ModelRuntime.swift` decode path **only when flag set**.
2. **Correctness gate first** (per `perf-mlx-compile-bf16-upgrade.md`): greedy token-id equality vs uncompiled on Gemma + gpt-oss + Qwen control.
3. **Then** run T0-02 matrix with flag on for MoE models only.
4. Measure resident RAM during decode (MoE fused-cache check — expect no +8–15 GiB spike).
5. Audit loop; PR separate from T1.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Token-exact + ≥3% decode TPS lift on Gemma **or** gpt-oss |
| **YELLOW** | Token-exact but <3% lift — document; keep flag off by default |
| **RED** | Output drift or RAM spike >2 GB vs uncompiled MoE |

### Artifacts

- `beta/throughput-engineering/T2-01-compiled-decode-wire-in.md`

---

## T2-02 — Port `DecodeBandwidthModel`

| Field | Value |
|-------|-------|
| **ID** | `T2-02` |
| **Question** | Can autotune/catalog diagnostics report **implied active params** from measured TPS? |
| **Prerequisites** | T0-02 data |

### Procedure

1. Add a clean-room `DecodeBandwidthModel.swift` under `phase3-binary/Sources/MacProviderCore/` from documented bandwidth equations and Macprovider measurements only; do not inspect external provider forks.
2. Unit tests for forward/inverse model.
3. Optional: `decode-bench --report-sparsity` flag emitting implied active params.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Tests pass; Gemma implied active params << 26B dense |
| **RED** | N/A — diagnostic only |

### Artifacts

- `beta/throughput-engineering/T2-02-decode-bandwidth-model.md`

---

# T3 — Provider-side optimizations (bucket B)

> **Goal:** TTFT and egress polish **without** architecture rewrites. Each item is independently WAIVABLE if <3% measured win.

---

## T3-01 — Token / chunk batching (`streamInterval`)

| Field | Value |
|-------|-------|
| **ID** | `T3-01` |
| **Question** | Does batching SSE frames every **4 tokens** reduce egress CPU without harming buyer TTFT perception? |
| **Prerequisites** | T0-03 profile (promoted if YELLOW+) |
| **Config** | `stream_interval` in config / `--stream-interval` (default **1** preserve behavior) |

### Procedure

1. In `InferenceRelay.processStreaming`, accumulate token deltas until N tokens or flush on stop.
2. Default **1**; production experiment at **4** (upstream production value).
3. Measure: WS sends/sec, CPU sample, buyer-visible first-chunk latency (should be ≤4 token times).
4. Do **not** adopt NWConnection.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | ≥10% reduction in send calls; no catalog TTFT gate regression |
| **WAIVE** | T0-03 GREEN and no measurable CPU win |

### Artifacts

- `beta/throughput-engineering/T3-01-stream-interval.md`

---

## T3-02 — Adaptive prefill spike

| Field | Value |
|-------|-------|
| **ID** | `T3-02` |
| **Question** | Can a **minimal** chunk sizer reduce TTFT p95 on 3k+ token prompts without BatchScheduler? |
| **Prerequisites** | TG1 |
| **Scope** | Spike only — port policy ideas from upstream `#466`, not full scheduler |

### Procedure

1. Read only the upstream `ml-explore` adaptive-prefill implementation and PR #466.
2. Prototype: optional chunked `processor.prepare` or mlx-swift-lm API if available; else document blocker.
3. Benchmark TTFT p50/p95 on 4096-token prompt (Stage1 probe shape).
4. Max 3 engineering days — if no API hook, record **NO-GO** and WAIVE.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GO** | ≥15% TTFT p95 reduction → create full BUILD spec |
| **WAIVE** | No hook or <15% win |

### Artifacts

- `beta/throughput-engineering/T3-02-adaptive-prefill-spike.md`

---

## T3-03 — KV quant family scheme

| Field | Value |
|-------|-------|
| **ID** | `T3-03` |
| **Question** | Should `kv_bits` defaults be model-family-specific (Gemma K8V8, etc.)? |
| **Prerequisites** | TG1; existing `--kv-bits` / autotune axis |

### Procedure

1. Map catalog models → recommended `GenerateParameters.kvBits` using only tagged upstream `ml-explore` APIs and Macprovider measurements.
2. Run autotune-style sweep: nil vs 4 vs 8 on Gemma long-context probe.
3. Gate on quality: no rise in autotune TTFT failures / stop anomalies.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | Documented family defaults + ≥10% KV headroom on target tier |
| **WAIVE** | Quality regression at 4-bit KV |

### Artifacts

- `beta/throughput-engineering/T3-03-kv-quant-scheme.md`

---

# T4 — Continuous batching / Engine V2 (bucket A+B, major)

> **Goal:** Multi-stream **aggregate** TPS. **Do not start** until TG2 or operator explicitly prioritizes concurrency over single-stream polish.

---

## T4-01 — Feasibility spike

| Field | Value |
|-------|-------|
| **ID** | `T4-01` |
| **Question** | Can MacProvider adopt `MLXLMCommon.CBv2Engine` without breaking Tier-2 relay, warm-swap, conversation cache, spec-decode? |
| **Prerequisites** | TG2 recommended; T1 merged |
| **Time box** | 1 week read-only + prototype branch |

### Procedure

1. Map only Engine V2 APIs present in tagged upstream `ml-explore` releases; if the required APIs are unreleased, record **BLOCKED** without inspecting forks.
2. List MacProvider integration points: `ModelRuntime`, `InferenceRelay`, `ConversationCache`, `ProviderStatus.throughputTPSSinceLast`.
3. Prototype: load Gemma in CBv2 on branch; single-stream parity vs current path.
4. Decision record: **GO** / **NO-GO** / **DEFER** with cost estimate.

### Artifacts

- `beta/throughput-engineering/T4-01-cbv2-feasibility.md`

---

## T4-02 — Engine V2 implementation

| Field | Value |
|-------|-------|
| **ID** | `T4-02` |
| **Question** | Ship CBv2 behind flag for MoE catalog models |
| **Prerequisites** | TG4; T4-01 **GO** |
| **Effort** | Multi-PR (4–8 weeks) — split: bridge → admission → warm-swap → prod flag |

### Procedure (high level)

1. PR-A: `EngineV2Bridge` port + factory; kill switch env `MACPROVIDER_ENGINE_V2=0`.
2. PR-B: Replace `maxBatch` semaphore semantics with scheduler capacity (KV budget).
3. PR-C: Relay multi-request lifecycle + cancel.
4. PR-D: Network harness scenario 07 sustained throughput re-baseline.

### Pass / fail

| Result | Criteria |
|--------|----------|
| **GREEN** | 2 concurrent streams ≥1.6× single-stream aggregate TPS on Gemma (**measure** on 32 GB) |
| **RED** | Correctness/cancel/settlement regression |

### Artifacts

- `beta/throughput-engineering/T4-02-cbv2-impl.md`

---

# DEFERRED — Explicit non-adopts

Document in `beta/throughput-engineering/DEFERRED.md`:

| Item | Reason |
|------|--------|
| #479 NWConnection transport | T0-03 structural egress analysis; MacProvider lacks upstream serial outbound bug |
| #480 ChunkBatcher / AsyncStream bypass | `BlockingChunkBuffer` + direct `sendFrame` already decouples |
| #476 shutdown actor hop | No matching hot-path structure |
| #475 serial WS outbound | Not present |
| v0.6.26 TCP_NODELAY | Requires NWConnection |
| #483 DH precompute | Session-level HKDF already (`Tier2ProviderSession.swift:79-100`) |
| bf16 weight cast | Empirically net-negative on M5 (`perf-mlx-engine.md`) — do not resurface |
| Layr-Labs fork submodule vendoring | Clean-room + maintenance — use ml-explore pins only |

Re-open only if T0-03 **RED** or TG4 concurrency mandate.

---

# Upstream watch (automated)

Pending throughput blockers are tracked in `beta/throughput-engineering/UPSTREAM_WATCH.json` and polled by `scripts/check-upstream-throughput-blockers.sh`.

| Upstream | Kind | Runbook | Cursor Automation |
|----------|------|---------|-------------------|
| [mlx-swift-lm#406](https://github.com/ml-explore/mlx-swift-lm/issues/406) | Issue | T2-01 / TG2 | Weekday blocker watch |
| [mlx-swift-lm#364](https://github.com/ml-explore/mlx-swift-lm/pull/364) | PR (**merged**, awaiting release tag) | T1-02 / TG1 | Weekday blocker watch |
| [mlx-swift-lm#312](https://github.com/ml-explore/mlx-swift-lm/issues/312) + [#453](https://github.com/ml-explore/mlx-swift-lm/pull/453) | Issue + PR (**PR merged**, awaiting release tag) | #965 / reusable quantized KV | Weekday blocker watch |
| [mlx-swift-lm#424](https://github.com/ml-explore/mlx-swift-lm/issues/424) | Issue | #377 / speculative rollback | Weekday blocker watch |
| [mlx-swift-lm#518](https://github.com/ml-explore/mlx-swift-lm/issues/518) | Issue | #700 / package consumption | Weekday blocker watch |
| ml-explore release tags | Release | T1-01 pin bump | Weekly discovery watch |
| `swift-transformers` release tags | Release | #966 token-exact migration | Weekly discovery watch |

When the checker exits **2** (material change: issue/PR closed or merged, new release above pin, KVCache compile-fix heuristic), the automation must first **open or update the sticky GitHub issue**, then persist the reviewed snapshot through a normal feature-branch PR. It must never open a draft dependency-bump or implementation PR. Concretely:

1. `gh issue list --repo Augustas11/macprovider --search "<sticky title>" --state all` to find the existing sticky issue for that blocker.
2. If found, add a comment with the new checker snapshot (state, timestamps, pin status) and update checkboxes; if not found, create it fresh.
3. For the mlx-swift-lm #364 (Gemma MoE) blocker specifically, the sticky issue is [#700](https://github.com/Augustas11/macprovider/issues/700) — "Awaiting mlx-swift-lm release containing #364 (Gemma MoE) — then T1-01 + T1-02". Always comment/update that issue rather than opening a new one while it stays open.
4. Track blocker `status` as `awaiting_release_tag` once the upstream PR/issue
   is merged/closed but no release tag yet contains it. `release_ready` requires
   all of: a newer tag containing the fix, upstream #518 closed/released, normal
   remote SwiftPM consumption, and a protected Xcode 16.4 / Swift 6.1 build.
   Even then, the pin bump remains blocked until every mandatory row in
   `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md` passes.

See `beta/throughput-engineering/CURSOR_AUTOMATION_UPSTREAM_WATCH_PROMPT.md` for the paste-ready automation prompt implementing this contract.

---

# Executor prompt template

```
Read: specs/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md § {TASK_ID}
Rules: CLAUDE.md worktree isolation; audit loop before GREEN on code tasks.
Deliver: artifacts under beta/throughput-engineering/
Do NOT update this plan unless asked — post artifact paths and PASS/FAIL.
```

---

# Status tracker

> **Maintained by:** executor agents + pinned planning session.  
> Last updated: 2026-07-07 (T3 merged)

| Task ID | Phase | Status | Gate | Artifact | Notes |
|---------|-------|--------|------|----------|-------|
| T0-01 | T0 | **`GREEN`** | TG0 | `T0-01-decode-bench-harness.md` | Merged #467 |
| T0-02 | T0 | **`YELLOW`** | TG0 | `T0-02-baseline-matrix.json` | Merged #467 |
| T0-03 | T0 | **`GREEN` (structural)** | TG0 | `T0-03-egress-profile.md` | Merged #468 |
| T0 rollup | T0 | **`DONE`** | **TG0** | `T0_SUMMARY.md` | CLOSED |
| T1-01 | T1 | **`BLOCKED`** | TG1 | `T1-01-mlx-pin-bump.md` | No tagged/package-consumable/protected-toolchain-compatible release passing the mandatory matrix |
| T1-02 | T1 | `BLOCKED` | TG1 | — | Waits mlx-swift-lm#364 release |
| T1-03 | T1 | **`GREEN`** | TG1 | `T1-03-metallib-rebuild.md` | Merged — metallib preflight GREEN |
| T2-01 | T2 | **`YELLOW`** | TG2 | `T2-01-compiled-decode-wire-in.md` | Merged #471 — flag OFF; blocked on [mlx-swift-lm#406](https://github.com/ml-explore/mlx-swift-lm/issues/406) |
| T2-02 | T2 | **`GREEN`** | — | `T2-02-decode-bandwidth-model.md` | Merged #470 |
| T3-01 | T3 | **`WAIVE`** | TG3 | `T3-01-stream-interval.md` | Merged #473 — default 1; egress not bottleneck |
| T3-02 | T3 | **`GREEN` (wire-in) / WAIVE default** | TG3 | `T3-02-adaptive-prefill-spike.md`, `T3-02-prefill-step-sweep.json` | Wire-in #474; 4k sweep flat — keep default 512 |
| T3-03 | T3 | **`GREEN`** | TG3 | `T3-03-kv-quant-scheme.md` | Merged #472 — Gemma/gpt-oss → kvBits 8 |
| T4-01 | T4 | `PENDING` | TG4 | — | Operator priority |
| T4-02 | T4 | `BLOCKED` | — | — | Needs T4-01 GO |

### Gate summary

| Gate | Status | Signed off |
|------|--------|------------|
| TG0 | **`CLOSED`** | 2026-07-07 (#467+#468) |
| TG1 | **`OPEN`** | T1-01 BLOCKED on #364/#518/#312/#424 and protected-toolchain/matrix gates |
| TG2 | **`OPEN`** | T2-01 blocked on [mlx-swift-lm#406](https://github.com/ml-explore/mlx-swift-lm/issues/406) |
| TG3 | **`CLOSED`** | 2026-07-07 (#472+#473 + T3-02 wire-in) |
| TG4 | `OPEN` | — |

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 0.1.0 | 2026-07-07 | Initial runbook from throughput engineering exploration |
| 0.1.1 | 2026-07-07 | T0-01 GREEN (decode-bench harness); T0-03 GREEN structural (egress trace); T0-02 spawned |
| 0.1.2 | 2026-07-07 | T0 complete — TG0 PROCEED; T0_SUMMARY + DEFERRED; T1-01 READY |
| 0.1.3–0.1.8 | 2026-07-07 | T0–T2 merges (#467–#471); see git history |
| 0.1.9 | 2026-07-07 | T3 complete (#472–#474); TG3 closed; T2-01 tracks mlx-swift-lm#406; T3-02 prefill sweep measured |
| 0.1.10 | 2026-07-07 | Land T1-01 + T1-03 artifact markdown on main |
