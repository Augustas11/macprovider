# Shard pipeline-over-WAN → MacProvider feasibility assessment

**Date:** 2026-07-07 (updated same day — shard clone refreshed)  
**Scope:** Read-only comparison of [shard](file:///Users/augstar/c0mpute-watch/shard) (reference clone at `182e93b`, includes PR #28 cwnd keep-warm) and MacProvider (this repo).

---

## 1. TL;DR verdict

**Go-with-caveats.** MacProvider should adopt shard's *distributed-systems* ideas—single-writer transport, framed activation messages, RTT/VRAM-aware ring placement, async inter-stage send, churn recovery, and per-stage signed receipts—but **not** its CUDA/PyTorch kernel stack. The headline prize (serving a model larger than one Mac's unified memory by sharding layers across Macs) is **blocked on MLX**: MacProvider today loads one full `ModelContainer` per process (`specs/SPEC-010-model-catalog.md:302`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:323`) and has no stage-local `forward(hidden, start_pos)` path. Upstream `mlx-lm` documents `sharded_load` + `model.pipeline()` for pipeline-parallel *weight* placement (`ml-explore/mlx` issue #3208, **inference** from public MLX discussion), but MacProvider's `mlx-swift-lm` integration exposes only end-to-end `generate`/`stream`—not cross-machine hidden-state I/O. **Transfer now:** transport hardening patterns and coordinator placement math. **Spike first:** a ~20-line MLX probe that loads layers `[lo:hi]`, runs one block, and returns a hidden tensor. **No-go for now:** porting CUDA graphs, NVFP4/fp8 KV, libp2p sidecar wholesale, or expecting 30 tok/s cross-Mac pipeline without a spec-decode coordinator and MLX stage runtime.

---

## 2. Architecture comparison

| Dimension | MacProvider (today) | shard (proven path) |
|-----------|---------------------|---------------------|
| **What splits** | Nothing at inference time. One model per provider process (`specs/SPEC-010-model-catalog.md:302`, `specs/SPEC-001-phase3-binary.md:186`). | Contiguous transformer layer blocks per GPU (`phase0/pipeline.py:3-7`, `shard/node.py:34-79`). |
| **What crosses the wire** | OpenAI-shaped chat JSON (buyer↔gateway↔coordinator↔provider). Inference payload is HTTP body or WS `inference_request` text frames (`phase4-coordinator/internal/ws/relay.go:160-172`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:219-274`). | Per-hop **hidden-state tensors** + control ops (`verify`, `reset`, `crop`) (`phase0/specpipe.py:136-148`, `shard/transport.py:44-58`). |
| **Transport** | Provider-initiated WSS to coordinator; Go `runWriter` single-writer relay (`phase4-coordinator/internal/ws/relay.go:160-172`). Optional HTTP forward to provider `:8080` (`phase4-coordinator/internal/buyer/server.go:1679-1696`). No libp2p sidecar in-repo. | Length-prefixed JSON+blob frames (`phase0/wire.py:131-161`, `shard/transport.py:94-105`). libp2p Go sidecar tunnels TCP (`sidecar/main.go:1-18`, `shard/transport.py:1-10`). |
| **Placement** | Per-provider model match + context + tier2 + quota; sort by throughput objective + sticky (`phase4-coordinator/internal/routing/filter.go:110-129`, `phase4-coordinator/internal/buyer/server.go:5084-5209`). `unified_memory_gb` is inventory/verification, not routing (`phase4-coordinator/internal/onboarding/store_pg.go:270-287`). | VRAM-fit contiguous blocks, fat-node-first, min-latency Hamiltonian ring (`shard/scheduler.py:67-91`, `shard/topology.py:27-34`). Coordinator placed in-region (`docs/NETWORK.md:40-44`). |
| **Trust / pay** | Per-provider **whole-request** receipts (SPEC-015): model hash, prompt hash, output prefix (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:26-52`). Coordinator-trusted settlement path. | Per-**stage** signed receipts chaining `in_root`/`out_root` per activation chunk (`shard/receipt.py:54-82`, `docs/INTEGRATION.md:120-125`). Coverage tiling `[0:layer_count)` (`shard/receipt.py:119-145`). |
| **Throughput model** | One Mac runs full decode; ~14 tok/s sustained on M1 8GB (`doc/PHASE1_REPORT.md` stress tests, **inference** from HANDOFF). | Pipeline + spec-decode + depth pipelining; ~30–40 tok/s on 3–6 GPU rings over WAN (`shard/README.md:29-31`, `shard/README.md:141-147`). |
| **Memory ceiling** | Model must fit one Mac: 8GB Air hard Metal OOM ~26K ctx (`doc/PHASE1_REPORT.md:224-249`, `HANDOFF.md:307-316`). `ModelFit` uses weight+headroom heuristic (`phase3-binary/Sources/MacProviderCore/ModelFit.swift:11-21`). | Model split across nodes; each holds `load_stage` slice only (`phase0/pipeline.py:81-126`). |

---

## 3. Research questions

### 3.1 CRUX — Pipeline parallelism on MLX (longest)

#### What shard does (the bar)

shard's `ModelRuntime` contract is explicit: a stage loads layers `[layer_range]`, runs `forward(hidden_states, start_pos)`, keeps KV locally, and hands activations to the next hop (`shard/node.py:34-79`). The hot path in `specpipe.py` receives `msg["h"]`, calls `run_block(...)`, and forwards `h.cpu()` (`phase0/specpipe.py:136-148`). `pipeline.load_stage` achieves single-node memory savings by mapping non-local layers to `"meta"` so only `[lo:hi]` weights land on GPU (`phase0/pipeline.py:81-106`). PyTorch/Transformers makes this straightforward because layers are addressable `nn.ModuleList` entries.

#### What MacProvider does today

MacProvider wraps **one** `ModelContainer` from `mlx-swift-lm`, loaded wholesale via `loadLocalContainer` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:323-347`, `1882+`). Generation is end-to-end: tokenize → `generate`/`stream` with per-layer KV inside the runtime (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1129`, `1459`). There is no code path that:

1. Loads only `model.layers[lo:hi]` (plus embed/norm/head at boundaries).
2. Accepts an incoming `[1, T, H]` hidden tensor from the network.
3. Returns an outgoing hidden tensor without running `lm_head`.

Normative specs lock **one active model per process** (`specs/SPEC-010-model-catalog.md:302`, `specs/SPEC-011-operator-pushed-warm-swap.md:266`).

#### MLX / mlx-lm / mlx-swift-lm — what we can and cannot claim

| Claim | Evidence | Confidence |
|-------|----------|------------|
| MLX Python stack has pipeline-parallel **weight** tooling (`sharded_load`, `model.pipeline()`) | Public MLX issue #3208 (**inference**; not present in either repo) | Medium — upstream docs, not verified in this workspace |
| `mlx-swift-lm` exposes per-layer forward with external hidden input | MacProvider only calls high-level `ModelContainer` + `generate` (`ModelRuntime.swift`) | **No in-repo evidence** of stage API |
| Hidden states are exposable in principle | `mlx-swift-lm` models are `Module` stacks; ekryski fork shows per-layer `batchedForward` over `layers` (`mlx-swift-lm` Qwen3 commit, **inference**) | Medium — would need adapter per architecture |
| MacProvider can shard today | Spec + code forbid multi-slice serving | **High — blocked** |

**Honest assessment:** We **cannot** assert that `mlx-lm` or `mlx-swift-lm` ships a drop-in equivalent to `pipeline.load_stage` + `run_block` for arbitrary HuggingFace architectures on MacProvider's Swift path. The Python MLX ecosystem appears closer (pipeline weight sharding), but MacProvider's production path is Swift/`mlx-swift-lm`. Bridging would require a **new `MLXStageRuntime`** (shard `ModelRuntime` analogue) that:

1. Loads a manifest-defined weight subset (embed if head, norm+lm_head if tail).
2. Implements `forward(hidden: MLXArray, startPos: Int) -> MLXArray` with a **per-stage KV cache** (shard: `shard/node.py:16-18`).
3. Serializes hidden tensors over the wire (bf16/fp16 bytes; shard uses pickle-free JSON+blob, `shard/transport.py:44-58`).

**What would have to change in MacProvider:**

- **Provider binary:** Replace monolithic `ModelRuntime.complete()` with stage mode when `MACPROVIDER_STAGE_LO/HI` (or coordinator assignment) is set.
- **Coordinator:** New job type that drives `coordinate_pipe`-style token orchestration (shard: `phase0/m25_pipe.py:151-157`) instead of forwarding full chat to one Mac.
- **Model catalog:** Layer-count + `gb_per_layer` + `hidden_size` for VRAM-fit (`shard/scheduler.py:58-65`).

**Bandwidth reality (decode):** shard documents per-traversal payload as `h_kb = (K+1) * H * 2 / 1024` KB (`phase0/m25_pipe.py:1368-1376`, `1464`). For M2.5 with `H=3072` (embed dims per `phase0/m25_pipe.py:122`) and spec-decode `K=6`: **~42 KB per hop per traversal**. At ~30 tok/s with ~7 tokens accepted per traversal (**inference** from shard README throughput claims), a stage sees ~4–5 traversals/s → **~170–210 KB/s uplink per hop** — well within typical residential 10–20 Mbps upload (**inference**).

**Bandwidth reality (prefill — the Mac-killer):** `specpipe.py` sizes socket buffers for **~24 MB** per prefill chunk (`phase0/specpipe.py:56-63`). `M25_ENGINE.md:36-38` (**inference** from shard docs in clone) states long-context prefill is **upload-dominated** on asymmetric residential links (100 MB+/hop → multi-minute TTFT). Mac uplinks are the same constraint class as GPU residential nodes.

**Verdict on crux:** **Blocked-on-MLX** for production; **feasible in principle** if a stage runtime spike succeeds. Without that spike, cross-Mac sharding is **no-go**.

---

### 3.2 Transport reuse

| shard mechanism | MacProvider analogue / gap | Transferability |
|-----------------|----------------------------|-----------------|
| **Single-writer socket ownership** | `runWriter` + `enqueueRaw` for all coordinator→provider WS writes (`phase4-coordinator/internal/ws/relay.go:160-172`, `phase4-coordinator/internal/ws/server.go:1317-1331`) | **Already shipped** — same pattern |
| **cwnd keep-warm on idle legs** | `_KeepWarm` daemon sends `{"op":"noop"}` when a send socket idles past `interval_ms`; `recv_data` skips noops (`phase0/m25_pipe.py:100-124`, `154-175`, `211-228`). Wired on coord→head (`417`), stage forward (`1064`), tail return (`1085`). Default **150 ms** for `--serve` gateway (`phase0/m25_scatter_pipe.py:133-139`). Env: `M25_CWND_KEEPWARM_MS` (default 0=OFF), per-job `M25_KEEPWARM_JOB` → `keepwarm_ms` on reset (`phase0/m25_pipe.py:112-113`, `416-435`, `1188-1189`). Tests: `tests/test_cwnd_keepwarm.py:1-9`. | **Transferable with adaptation** — targets **TCP stage-to-stage** idle between decode traversals, not MacProvider's buyer JSON path. MacProvider has write deadlines (`phase4-coordinator/internal/ws/relay.go:228-234`) but no app-level cwnd keep-warm. A MacProvider port would need a WS-safe noop/ping that `InferenceRelay` ignores — same risk called out in Phase 1 below. |
| **Churn re-dial / adopt** | shard: edge `EDGE_ERRORS` resets connection (`phase0/node_kv.py:26-34`, `phase0/m25_pipe.py:520-526`); hot heal rewires predecessor (`STATE.md:80-85`) | **Partial** — MacProvider: receive/handle decoupling (`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:950-967`), `waitUntilIdle` before reconnect (`CoordinatorClient.swift:499-504`), retired request TTL (`phase4-coordinator/internal/ws/relay.go:30`, `369-407`) |
| **Framed length-prefixed messages + size caps** | shard: `!Q` length + JSON+blob (`phase0/wire.py:142-161`); PR #24 proposes `SHARD_MAX_FRAME` (**inference**) | **Transferable** — MacProvider inference frames are JSON text over WS without tensor blobs; if activations are added, adopt shard framing in a new `phase4-coordinator/internal/stage/` codec |
| **Async inter-stage send** | `_AsyncSender` thread + 32 MB SO_SNDBUF (`phase0/specpipe.py:56-97`) | **Transferable** when MacProvider has multi-hop activation forwarding (not applicable to current buyer→single-provider relay) |
| **TCP_NODELAY** | Set on shard stage sockets (`phase0/m25_pipe.py:30`, `475`) | **Transferable** — worth explicit `TCP_NODELAY` on coordinator relay TCP if not already set (**inference** for MacProvider WS stack) |
| **libp2p sidecar** | `sidecar/main.go:1-18` — identity, NAT, activation streams | **Optional later** — MacProvider uses outbound WSS from Mac (`HANDOFF.md:52-53`); NAT is already solved by provider-initiated WS. libp2p adds value for permissionless **provider-to-provider** legs, not buyer path |
| **Pickle-free + AEAD** | `phase0/wire.py:16-24` ChaCha seal; libp2p drops PSK (`shard/transport.py:108-115`) | **Pattern transferable** — MacProvider already uses JSON WS + tier-2 encryption for sensitive paths; tensor frames would need pickle-free codec |

**Side-by-side: same problem, different shape**

```
shard stage chain:  coord ──[hidden tensor]──► stage0 ──► ... ──► tail ──[toks]──► coord
MacProvider today:  buyer ──[chat JSON]──► gateway ──► coordinator ──[inference_request JSON]──► provider ──► MLX full model
```

---

### 3.3 Placement / scheduling

shard's `Scheduler.allocate` distributes layers proportional to VRAM capacity, fat nodes first, contiguous blocks (`shard/scheduler.py:67-91`). `topology.optimal_loop` minimizes measured asymmetric RTT (`shard/topology.py:27-34`). `scheduler_svc.py` (**inference:** open PR #6, not in clone) would expose HTTP `/plan`.

MacProvider's `EligibleCandidates` filters by model ID, context, tier2, quota (`phase4-coordinator/internal/routing/filter.go:110-129`) and sorts by throughput + sticky (`phase4-coordinator/internal/buyer/server.go:5084-5209`). `ProviderCapacity` maps physical RAM → max context/concurrency (`phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:61-71`) but is **per-node**, not per-layer-block.

**Transferable concepts:**

- Treat `unified_memory_gb` + `gb_per_layer` (from catalog) like `shard/scheduler.py:58-65` to decide how many layers fit per Mac.
- Add **swarm** as a first-class pool object: coordinator picks `{mac_a: [0:20], mac_b: [20:40], ...}` instead of one `model_id` match.
- Place coordinator (or draft Mac) **in-region** with the ring (`docs/NETWORK.md:40-44`) — for MacProvider, prefer coordinator on VPS near the densest provider cluster, or run draft on the lowest-RTT Mac.

**Not directly portable:** shard's EWMA tok/s objective (`signals.md` **inference**) — MacProvider lacks per-layer timing telemetry.

---

### 3.4 Trust / payment — per-stage receipts

shard: each stage signs `{swarm_id, job_id, layer_start, layer_end, in_root, out_root, n_chunks}` (`shard/receipt.py:76-82`). Coordinator collects receipts; `verify_coverage` tiles layers (`shard/receipt.py:119-145`). Payment attribution is per signed receipt (`docs/INTEGRATION.md:120-125`).

MacProvider: **whole-request** receipt binds model hash, prompt, output (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:26-52`). One provider serves the full model; receipt proves that provider's work, not a layer block.

**Template value for permissionless providers:**

| Property | shard receipts | MacProvider today |
|----------|----------------|-------------------|
| Coordinator can't forge stage work | Needs stage private key (`shard/receipt.py:8-10`) | N/A — single provider signs |
| Pay without proof | Blocked per stage | Provider must sign request receipt |
| Stage-level challenge | `shard/challenge.py:32-53` feeds known activation | No analogue (coordinator canary is prompt-based, `docs/INTEGRATION.md:115-117`) |

**Inference:** Per-stage receipts are a **usable template** if MacProvider moves to multi-Mac swarms. Would extend SPEC-015 or add SPEC-0XX swarm receipts. MacProvider's existing Ed25519 receipt keys (`ReceiptBuilder.swift`) could be reused per stage process.

---

### 3.5 What does NOT transfer

**Non-transferable (kernel / quantization / GPU):**

- CUDA graphs for verify (`phase0/m25_pipe.py:401-412`, `STATE.md:57-63`)
- NVFP4 / fp8 KV / `matmul_ogs` MoE kernels (`STATE.md:61-63`)
- `flex_attention` / flash-sink Hopper paths (`STATE.md:160-164`)
- GPU P2P / NCCL assumptions in vLLM (`docs/MODEL_RUNTIME.md:20-23`)
- `M25_FP8_WIRE` activation quant (`phase0/m25_pipe.py:39-68`) — could inspire **Metal-side** compression but not copy-paste

**Transferable (distributed systems):**

- Ring topology + direct-return tail (`phase0/m25_pipe.py:426-463`, `shard/README.md:60-64`)
- Speculative decode coordinator (`phase0/m25_pipe.py:151-157`, `phase0/specpipe.py:1-10`)
- Pipelined depth (`coordinate_pipe` depth parameter)
- Manifest + content-addressed shard fetch (`shard/manifest.py` per `docs/INTEGRATION.md:84-94`)
- Heal-by-rebuild + resume_ids (`STATE.md:80-85`, `phase0/m25_pipe.py:165`)
- Edge supervision `EDGE_ERRORS` (`phase0/node_kv.py:26-34`)

---

## 4. Three lists

### Transferable now

1. Single-writer WS relay pattern (`phase4-coordinator/internal/ws/relay.go:160-172`) — already present.
2. Receive/handle decoupling on provider WS (`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:950-967`).
3. Retired-request TTL for stale relay frames (`phase4-coordinator/internal/ws/relay.go:30`, `369-407`).
4. Write-probe before dispatch (`phase4-coordinator/internal/ws/relay.go:31`, `729-734`).
5. Pickle-free length-prefixed tensor framing design (`phase0/wire.py:131-161`, `shard/transport.py:94-105`) — for any future activation wire.
6. VRAM-fit layer allocation algorithm (`shard/scheduler.py:21-91`) — adapt `gb_per_layer` from catalog using `unified_memory_gb`.
7. RTT-optimal ring ordering (`shard/topology.py:27-34`) — feed from coordinator mesh probes.
8. Per-stage receipt **design** (`shard/receipt.py`, `docs/INTEGRATION.md:120-125`) — spec work, not code yet.
9. cwnd keep-warm pattern (`phase0/m25_pipe.py:100-228`, `tests/test_cwnd_keepwarm.py:1-9`) — applicable when MacProvider adds inter-provider TCP/tensor legs or measures cwnd collapse on coordinator relay.

### Blocked-on-MLX

1. Load contiguous layer slice + run isolated forward (`shard/node.py:71-75` vs `ModelRuntime.swift:323+`).
2. Per-stage KV cache with `start_pos` crop for spec-decode rollback (`shard/node.py:16-18`, `phase0/specpipe.py:133-134`).
3. Cross-Mac hidden tensor serialize/deserialize in Swift/MLX.
4. Head/tail split (embed / norm+lm_head) on MLX (`shard/node.py:21-22`).
5. Any claim of serving 70B+ on 8GB Air via sharding without a working stage runtime.

### Not applicable

1. CUDA graphs, NVFP4, fp8 MoE kernels (see §3.5).
2. libp2p sidecar as **required** transport — MacProvider's outbound WSS solves contributor NAT (`HANDOFF.md:52-53`).
3. GPU UUID / `nvidia-smi` telemetry — MacProvider uses chip + `unified_memory_gb` (`phase4-coordinator/internal/onboarding/store_pg.go:270-287`).
4. Whole-model-per-GPU VRAM sizing identically — unified memory includes KV + activations + macOS pressure (`HANDOFF.md:82-86`, `ModelFit.swift:11-15`).
5. shard's c0mpute payment rails (`docs/INTEGRATION.md:171-179`) — MacProvider has its own billing (`phase4-coordinator/internal/billing/`).

---

## 5. Phased implementation sketch (go-with-caveats)

### Phase 1 — Transport pattern reuse (lowest risk)

**Goal:** Harden MacProvider's existing WS relay; add optional keep-warm only if a spike shows cwnd/jitter regression on the coordinator↔provider leg (shard's `_KeepWarm` is proven for **stage TCP** at `phase0/m25_pipe.py:100-228`, not WSS JSON).

**Touches:**
- `phase4-coordinator/internal/ws/relay.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`

**Biggest risk:** Naive port of shard's `{"op":"noop"}` on WS text frames could confuse `InferenceRelay` JSON parser — would need typed noop/ping that the relay ignores (shard solves this with `recv_data` filtering at `phase0/m25_pipe.py:224-227`).

---

### Phase 2 — Memory-aware swarm placement (coordinator only)

**Goal:** Given catalog `layer_count` + `bytes_per_layer`, compute feasible multi-Mac assignments using `unified_memory_gb`; no MLX stage execution yet.

**Touches:**
- `phase4-coordinator/internal/routing/` (new `swarm` package)
- `phase4-coordinator/internal/pool/provider.go` (expose memory tier)
- `specs/` catalog entries with layer metadata

**Biggest risk:** Catalog lacks reliable `gb_per_layer` for MoE models — wrong fit math → OOM on stage Mac.

---

### Phase 3 — MLX stage runtime spike

**Goal:** One Swift/Python probe: load `mlx-community/*` layers `[0:N/2]`, accept random `[1,1,H]`, return hidden — bit-compare against full-model reference for that block.

**Touches:**
- New `phase3-binary/Sources/macprovider-cli/StageRuntime.swift` (or Python sidecar prototype)
- `beta/` spike script only (not production path)

**Biggest risk:** Spike succeeds on Llama-3.2-3B but fails on MoE / GDN hybrids (Qwen3.5, Nemotron) — per-architecture adapters required (`docs/MODEL_RUNTIME.md:46-50`).

---

### Phase 4 — Two-Mac pipeline POC (LAN)

**Goal:** 2 Macs, 1 model, split at layer N/2; coordinator drives verify loop; measure tok/s and bytes/hop on LAN before WAN.

**Touches:**
- `phase4-coordinator/internal/buyer/server.go` (swarm dispatch)
- `phase3-binary/` stage mode + activation codec
- New inter-provider transport (WSS hub or direct TLS between providers)

**Biggest risk:** Inter-provider transport + auth — MacProvider today has no provider↔provider channel (only provider→coordinator).

---

### Phase 5 — WAN spec-decode coordinator

**Goal:** Replicate shard's `coordinate_pipe` depth pipelining + n-gram/EAGLE draft on a Mac coordinator (`phase0/m25_pipe.py:151-200`).

**Touches:**
- Coordinator generation driver (new package)
- Provider stage runtimes on 3+ Macs
- Per-stage receipts (`shard/receipt.py` pattern)

**Biggest risk:** Without spec-decode, WAN latency caps at ~1–2 tok/s (`shard/README.md:47-49`) — unusable for buyers.

---

## 6. Open questions (spike / experiment)

| # | Question | Minimal probe |
|---|----------|---------------|
| 1 | Does `mlx-swift-lm` expose per-layer forward with injectable hidden state? | 20-line Swift: load `LlamaModel`, call `model.layers[0](h, ...)` with dummy `MLXArray`, `mx.eval` output shape |
| 2 | Can weights be loaded for `[lo:hi]` only from safetensors without full RAM spike? | Python `mlx_lm` `sharded_load` PP mode on 8GB Air (**inference** from MLX #3208) |
| 3 | What is `H` and bytes/hop for MacProvider's target catalog models? | Log `hidden_size` from config + apply `m25_pipe.py:1464` formula |
| 4 | Can residential Mac **upload** sustain N-hop prefill? | Throttle egress to 20 Mbps on LAN test; measure TTFT with 4K/16K prompts |
| 5 | Does cwnd collapse bite MacProvider coordinator→provider WS? | A/B TTFT variance with/without keep-warm; shard baseline is `M25_KEEPWARM_JOB` interleaved toggle (`tests/test_cwnd_keepwarm.py:277-305`) and measured 30KB–1.6MB frame cost at idle=900ms (`phase0/m25_pipe.py:103-104`, `tests/test_cwnd_keepwarm.py:3-5`) |
| 6 | Per-architecture parity after stage split? | Same prompt through full model vs 2-stage LAN — greedy token match |
| 7 | Where should draft model run for MLX spec-decode? | Shard uses separate GPU (`phase0/specpipe.py:12-13`); on Mac, draft likely second process on largest RAM machine |

---

## 7. Side-by-side: solving WAN jitter

| Problem | shard | MacProvider |
|---------|-------|-------------|
| WS/frame corruption | N/A (TCP/tensor frames) | Single `runWriter` (`phase4-coordinator/internal/ws/server.go:1317-1331`) |
| Idle socket cwnd collapse | `_KeepWarm` posts `{"op":"noop"}` on idle **send** sockets; receivers skip via `recv_data` (`phase0/m25_pipe.py:100-107`, `211-228`) | Not implemented (WS path; no stage-to-stage tensor legs yet) |
| Provider read buffer backup | Async send on stages (`phase0/specpipe.py:61-97`) | Receive/handle split (`CoordinatorClient.swift:950-967`) |
| Stale session frames | Edge reset (`phase0/node_kv.py:161-165`) | `retiredRelayRequestTTL` (`relay.go:30`) |
| Mid-request node death | Hot heal + `resume_ids` (`STATE.md:80-85`) | Retry other provider (`buyer/server.go` forward loop) — no KV resume |

---

## 8. References (in-repo)

**MacProvider:** `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`, `doc/PHASE1_REPORT.md`, `specs/SPEC-001-phase3-binary.md`, `specs/SPEC-010-model-catalog.md`, `phase3-binary/`, `phase4-coordinator/`, `phase5-gateway/`.

**shard (clone `182e93b`):** `README.md`, `STATE.md`, `docs/NETWORK.md`, `docs/INTEGRATION.md`, `docs/MODEL_RUNTIME.md`, `docs/paper/main.typ`, `phase0/m25_pipe.py` (incl. `_KeepWarm` PR #28), `phase0/m25_scatter_pipe.py`, `phase0/pipeline.py`, `phase0/specpipe.py`, `phase0/wire.py`, `shard/node.py`, `shard/transport.py`, `shard/scheduler.py`, `shard/topology.py`, `shard/receipt.py`, `shard/challenge.py`, `sidecar/main.go`, `tests/test_cwnd_keepwarm.py`.

**External (inference only):** MLX issue #3208 (PP `sharded_load`).

---

## 9. Appendix: `_KeepWarm` (cwnd keep-warm) — verified in clone

**Problem:** Serial pipeline decode idles every ring leg for a full traversal between frames. TCP `slow-start-after-idle` collapses cwnd; on a measured 40ms-RTT leg, idle≤300ms keeps 30KB–1.6MB frames at ~1 RTT, idle=900ms costs 2–4 RTTs (cwnd_p50 167→94). Kernel `tcp_slow_start_after_idle` is read-only in rental containers, so the engine warms sockets in userspace (`phase0/m25_pipe.py:101-107`, `tests/test_cwnd_keepwarm.py:3-5`).

**Mechanism:**

1. `_KeepWarm` wraps each **sending** socket; a daemon thread (`cwnd-keepwarm`) calls `_noop_once()` when idle > `interval_ms` (`phase0/m25_pipe.py:177-192`, `154-175`).
2. Noop payload: `send_msg(sock, {"op": "noop"})` (`phase0/m25_pipe.py:169`).
3. All real sends go through `kw.send()` — same lock as noop thread to prevent interleaved partial frames (`phase0/m25_pipe.py:110-112`, `148-152`).
4. Receivers use `recv_data()` which loops until a non-noop message (`phase0/m25_pipe.py:211-228`).
5. Churn-safe: non-blocking lock acquire, 2s-bounded noop send, `attach()` swaps socket without closing (`phase0/m25_pipe.py:115-124`).

**Deployment defaults:**

| Mode | `M25_CWND_KEEPWARM_MS` | Source |
|------|------------------------|--------|
| One-shot coord / benchmarks | `0` (OFF) | `phase0/m25_pipe.py:112-113` |
| Interactive `--serve` gateway | `150` if unset | `phase0/m25_scatter_pipe.py:133-139` |
| Per-job A/B | `M25_KEEPWARM_JOB` → `keepwarm_ms` on reset op | `phase0/m25_pipe.py:416-435`, `1188-1189` |

**Tests:** `tests/test_cwnd_keepwarm.py` (CPU/fake-ring; run `python3 -m pytest tests/test_cwnd_keepwarm.py -q` in shard tree). Not executed in this pass — `pytest` absent on host Python 3.14.

**MacProvider transfer note:** This is **not** a throughput lever on calm rings (shard labels it tail-latency/jitter). It matters on jittery/residential paths when MacProvider eventually ships **provider↔provider activation TCP** (Phase 4+). For today's coordinator↔provider WSS JSON relay, benefit is unproven and requires a measured spike (open question #5).

---

## 10. Spike 01 result (2026-07-07)

**Status: GO on MLX primitive (Llama-only).**

Added `phase3-binary/Tests/mlx-stage-spikeTests/StageForwardParityTests.swift` — two tests that load a cached Llama snapshot, run `layers[0..<lo]` + `layers[lo..<end]` on hidden state with per-layer KV cache, and assert staged greedy argmax equals full-model forward on a single token. Verified **PASS** against `mlx-community/Llama-3.2-3B-Instruct-4bit`.

Open question #1 (§6) is answered for Llama. Cross-Mac sharding remains blocked on coordinator/runtime wiring, partial weight load (open question #2), and catalog matrix parity (Spike 02+).
