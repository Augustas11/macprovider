# RESEARCH PROMPT — KV cache survival across process restarts for macprovider

Run as: `omc ask codex "$(cat specs/RESEARCH_233_KV_SURVIVAL_RESTART_PROMPT.md)"`

This is a **technical research prompt**, not a code-audit prompt. Single
codex call (or twice with different models). Output is a decision-grade
memo, not a diff.

**Status:** PARKED for a future implementation session. Research first;
no runtime changes in the research turn.

**Explicit non-goal:** adopt oMLX as macprovider's inference engine.
oMLX's **tiered SSD KV cache** is a reference design; evaluate patterns
portable to mlx-swift-lm.

**Upstream context:**
- [RESEARCH_223_MLX_THROUGHPUT_ROADMAP_MEMO.md] — prefix-cache reuse
  listed as ROI bet
- [RESEARCH_232_MULTISTREAM_BATCHING_PROMPT.md] — batching interacts with
  KV layout (coordinate but separate implementation)
- Entry 119 (DECISION_CRITERIA) — `kv_cache_request_completed` telemetry
- `ConversationCache.swift` — in-RAM LCP reuse per `conversation_key`
- oMLX FAQ: TTFT drops from 30–90s → <5s on long contexts after restart
  when SSD cache hits (marketing; verify independently)

---

## Task

Macprovider's `ConversationCache` reuses KV state **in-process only**:
keyed by `conversation_key`, LCP-trimmed, LRU-evicted, TTL-expired.
Provider restarts (deploy, crash, supervisor relaunch, warm-swap model
reload) **destroy** all KV state. Buyers with long multi-turn sessions
pay full prefill cost again.

Audit **KV persistence across process restarts** options for Apple
Silicon MLX stacks as of 2026-07-09 and recommend **one primary
approach** for macprovider to pursue later, with security/attestation
implications spelled out.

---

## Background — macprovider KV reuse today

### ConversationCache (`ConversationCache.swift`)

| Property | Value |
|---|---|
| Storage | In-RAM `[KVCache]` layers per conversation key |
| Reuse trigger | `conversation_key` on coordinator relay / HTTP request |
| Hit condition | LCP ≥ 32 tokens, same `modelID`, same `kvBits`, trimmable layers |
| Eviction | LRU + TTL (default 15 min) + token budget (200k) |
| Telemetry | `kv_cache_reuse_ratio`, `kv_cache_bytes_reused` (Entry 119) |
| Spec decode | Reports zero reuse (separate cache path) |

**Lost on:** process exit, model warm-swap, `kv_bits` change, model ID
change, non-trimmable cache layers.

### B1 idle prewarm (SPEC-017)

Idle prewarm loads model weights but does not persist KV across restart.
Research must address interaction: persisted KV blocks + prewarm should
reduce cold TTFT without breaking memory budgets.

### oMLX reference architecture (observed, not adopted)

- **PagedCacheManager** — GPU block-based KV, copy-on-write, prefix sharing
- **Hot tier** — RAM, write-back
- **Cold tier** — SSD (`PagedSSDCacheManager`), safetensors blocks, LRU
- Survives server restart; prefix blocks restored from disk

Independent benchmark (Mac O'Clock, Jun 2026): oMLX's win over mlx-lm
shows most clearly on **post-restart** long-prefix requests, not warm
in-memory repeats.

### Trust boundary

KV cache bytes are **not** attested today. `model_hash` attests weights,
not cached activations. Any persistent KV store introduces:
- stale-prefix risk after model revision change
- cross-tenant leakage if keys collide
- disk side-channel / forensic exposure of prompt prefixes

---

## What to produce

### Part 1 — Problem quantification

Estimate **provider-side cost** of KV loss on restart for macprovider
workloads:

| Workload | Typical prompt tokens | Prefill cost | Restart frequency |
|---|---:|---|---|
| Single-turn buyer | 1–4k | 1× per request | per deploy |
| Multi-turn chat | 4–32k growing | partial reuse today | per deploy |
| Coding agent | 8–64k system+tools | high | crash + deploy |

Use oMLX PP/TG data and macprovider `decode-bench` baselines where
available. Express as **seconds of TTFT** and **$/M-token opportunity
cost** (directional, not pricing change).

### Part 2 — Landscape audit

For each system, report persistence model, format, invalidation rules,
license, maturity:

| System | Persistence |
|---|---|
| **oMLX** PagedSSDCacheManager | safetensors blocks on disk |
| **mlx-lm server** | in-RAM prompt cache only (verify current version) |
| **vllm-mlx** | SSD cache claims (RESEARCH_223) |
| **llama.cpp** | slot save / cache files |
| **LM Studio / Ollama** | observable behavior only |
| **colibri** `.coli_kv` (Apache-2.0, single-user) | append-only compressed KV per turn on disk; resume at startup w/ zero re-prefill; crash-safe. **Legally inspectable/vendorable prior art** (cf. oMLX observe-only, d-inference clean-room-blocked) |
| **macprovider ConversationCache** | in-RAM only (baseline) |

> **colibri caveat:** its `.coli_kv` cost (~182 KB/token) is GLM **MLA** compressed
> KV (576 floats/token); macprovider catalog models are mostly **GQA** — re-derive
> bytes/token, do **not** transfer the number. colibri is single-user local and
> carries **none** of macprovider's invalidation/isolation requirements (Part 4) —
> it validates the *mechanism* (append-per-turn + resume), not the *trust boundary*.

### Part 3 — Design options for macprovider

Evaluate **five approaches**:

| ID | Approach | Summary |
|---|---|---|
| **A** | **Extend ConversationCache with disk tier** | Block-serialize KV layers to `~/.cache/macprovider/kv/`. **Prior art:** colibri `.coli_kv` append-only per-turn format (Apache-2.0, inspectable) — study its block/compression layout, but add the Part 4 invalidation + cross-tenant isolation colibri omits |
| **B** | **Prefix hash store + rehydrate** | Store prompt tokens + metadata; re-prefill from hash match. **Prior art:** colibri startup-resume w/ zero re-prefill (append + replay on load) demonstrates the rehydrate path end-to-end |
| **C** | **Upstream mlx-swift-lm paged KV API** | Wait/contribute portable paging primitives |
| **D** | **External sidecar cache** (oMLX-compatible format) | Process boundary; macprovider orchestrates keys |
| **E** | **Do nothing** | Rely on in-RAM + B1 prewarm; accept restart tax |

For each:

- engineer-month cost (range)
- expected TTFT reduction on restart (p50 / p95)
- RAM disk budget impact
- compatibility with `kv_bits`, warm-swap, spec-decode
- security / attestation impact (new threat table)

### Part 4 — Security and attestation analysis

Required threat table:

| Threat | A | B | C | D | E |
|---|---|---|---|---|---|
| Stale cache after `model_sha256` change | | | | | |
| Cross-provider leakage on shared Mac | | | | | |
| Prompt prefix recovery from disk | | | | | |
| Coordinator receipt mismatch | | | | | |
| OPoI drift false positives | | | | | |

Recommend **mandatory invalidation rules** (e.g. invalidate all blocks
when `model_hash` changes, when `kv_bits` changes, when catalog revision
changes).

Clarify whether persistent KV requires a **new attestation field** or
remains provider-local optimization (no buyer API change).

### Part 5 — Interaction with RESEARCH_232 batching

Document conflicts and synergies:

- Paged KV blocks + continuous batching share memory layout assumptions
- Should persistence land **before** or **after** batching work?
- Recommend **sequencing** (default: persistence first if TTFT wins are
  independent of batching; batching first if shared paged-KV design)

### Part 6 — Bench scenarios (future session)

| ID | Scenario | Metric |
|---|---|---|
| `KVS-01` | 8k prefix, complete, kill process, repeat | TTFT p95 |
| `KVS-02` | model warm-swap same family | cache miss expected |
| `KVS-03` | `model_sha256` change | full invalidation |
| `KVS-04` | 24h disk cache size on M4 Max 64GB | disk GB |
| `KVS-05` | B1 prewarm + persisted KV | TTFT after idle |

Define pass thresholds relative to in-RAM warm baseline.

### Part 7 — Recommendation and milestones

One **primary approach** + fallback + no-go list.

Quarterly milestones (2026–2027) with gates tied to KVS bench IDs.

---

## Out of scope

- Implementing persistence (future BUILD_SPEC)
- oMLX runtime integration
- Multi-stream batching implementation (RESEARCH_232)
- Buyer-visible `cached_tokens` billing changes (coordinator authority)
- Normative SPEC edits in this turn

---

## Output format

Markdown memo `specs/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md`,
**~400–700 lines**.

Executive summary ≤ 10 bullets. Threat table in Part 4 required.
Architecture diagram (RAM + disk tiers) encouraged.

Conservative > optimistic on TTFT reduction claims; separate oMLX
marketing numbers from replicated measurements.
