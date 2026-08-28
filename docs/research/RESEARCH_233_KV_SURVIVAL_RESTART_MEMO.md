# RESEARCH_233 — KV Survival Across Provider Restarts

| Field | Value |
|---|---|
| Status | Decision memo; research only |
| Date | 2026-07-22 |
| Repository baseline | `origin/main` at `41b60c1f` |
| Decision horizon | 2026–2027 |
| Scope | Apple Silicon, `mlx-swift-lm`, and macprovider's provider-local prefix cache |

## Executive summary

- The measured problem is a restart/contention tail, not a calibrated cold-to-warm delta: 1,492 live buyer-runner round trips measured p50 3.9 s, p95 16.8 s, p99 51.4 s, and max 186 s; 62 requests (4.2%) exceeded 20 s. The dedicated cold/warm store contains zero usable samples, so no absolute KV-persistence TTFT saving is yet established.
- Persisted KV should target deploy, crash, supervisor relaunch, and reboot re-prefill. Natural idle-cold is largely masked because the buyer-runner calls the live 32 GB M5 provider every five minutes and thereby acts as a de-facto prewarm.
- Pursue **Approach A: an encrypted, provider-namespaced disk tier behind the existing `ConversationCache`**, using versioned append-only blocks, atomic manifests, strict metadata validation, and bounded streaming promotion into the current RAM cache.
- Approach A is brownfield: commit `84e50c92` already proved exact-LCP plus `KVCache.trim()` produces correct multi-turn output and exposed the tokenizer, token-accounting, and `cache_offset` traps that persistence must preserve.
- Keep the first disk format independent of RESEARCH_232's future shared paged-KV allocator. Run persistence first only while it can serialize the current per-conversation layer state opaquely; if KVS-01 requires a new paged attention layout, stop and sequence batching/paged-KV first.
- The mandatory safety envelope is stricter than colibri or local single-user tools: exact `model_sha256`, model/catalog revision, tokenizer/template identity, `kvBits`, quantization metadata, cache class/layout, and ABI compatibility; any ambiguity, corruption, expiry, or incomplete write is a miss.
- Cross-account isolation still rests on SPEC-024 FR-CI5/CI6's account-scoped unforgeable `conv:` key. Persistence widens a failure from one process lifetime to restarts and peer processes, and converts the existing global-capacity channel into a possible cross-process denial vector unless disk namespaces and quotas are per provider.
- Do not ship a disk tier until a provider-side conversation-key purge primitive exists. `DELETE /v1/sticky` currently removes only coordinator state; a restart-durable provider entry would otherwise remain buyer-unpurgeable.
- Persistent KV remains a provider-local performance optimization. It introduces no new receipt field and must not change locked SPEC-015 v0.4.2 receipts; buyer-facing cache binding, if ever required, is a named future SPEC-015 v0.5 question rather than a retrofit.
- Fallback to **Approach C**, an upstream portable `mlx-swift-lm` save/load or paging primitive wrapped in the same policy envelope. Do not adopt an external sidecar, global cross-tenant deduplication, plaintext token replay as the production cache, or oMLX as the inference engine.

## Decision

Build and benchmark a provider-local cold KV tier as an extension of the shipped `ConversationCache`. The first implementation should preserve the existing hot-cache semantics:

1. `conversation_key` selects one conversation candidate.
2. Token-level LCP determines the reusable prefix.
3. Every layer must trim exactly to the LCP.
4. The incoming request still reports its full prompt length.
5. Speculative decoding remains outside this cache path.

The disk tier should change residency, not cache eligibility, billing, receipts, or buyer-visible semantics. The stop condition for the first investment is explicit: if KVS-01 cannot approach the in-RAM warm baseline without replacing the current KV layout with a shared paged allocator, pause Approach A and move to the Approach C / RESEARCH_232 layout decision before doing more persistence engineering.

---

## 1. Problem quantification

### 1.1 What is measured

RESEARCH_234 provides the only current macprovider production measurement suitable for this memo. The passive sample contains 1,492 real, non-streaming buyer-runner round trips against the live provider:

| Property | Observed value |
|---|---:|
| Provider model | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` |
| Host | 32 GB M5; also the production `mac` provider |
| Request cadence | approximately 5 minutes |
| Response cap | at most 120 tokens |
| p50 end-to-end latency | 3.9 s |
| p90 | 10.9 s |
| p95 | 16.8 s |
| p99 | 51.4 s |
| Maximum | 186 s |
| Requests over 20 s | 62 / 1,492, or 4.2% |

**Evidence label: RESEARCH_234 measured.** These are variable-length, end-to-end round trips rather than controlled TTFT samples. They show the lived tail that a restart-resilient cache could reduce, but they do not isolate model load, queueing, prompt prefill, token generation, or provider contention. The older 2026-07-10 observation, p95 65 s and p99 93 s, is directionally consistent with a severe tail but is not substituted for the current snapshot.

### 1.2 What is not measured

The dedicated store at `~/.local/state/coldwarm-ttft/coldwarm-samples.ndjson` contained 42 records at the RESEARCH_234 snapshot. All 42 were HTTP 503 `no_provider_available` failures from a provider-down seed run:

- `ok=0` for every row;
- `ttft_ms=null` for every row;
- zero usable warm samples; and
- zero usable `post_reboot` cold samples.

Therefore the controlled cold-to-warm delta is **not yet measured**. This memo does not invent a cold-load duration, a seconds-per-token prefill rate, or an absolute post-restart TTFT saving. The oMLX statement that long-context TTFT falls from “30–90 s” to “under 5 s” on an SSD hit is **unreplicated upstream marketing**, not a macprovider result. It is useful only as a hypothesis generator for KVS-01.

### 1.3 Where the restart tax occurs

The development Mac is the production `mac` provider, with one roughly 32 GB resident model on a 32 GB machine. There is no separate lab Mac on which repeated cold induction is operationally safe. The buyer-runner's five-minute cadence also keeps production from becoming naturally idle-cold in most periods. Consequently, the forcing function is narrower than the original prompt suggested:

- deploys;
- crashes;
- supervisor relaunches;
- host reboots; and
- model replacement or warm-swap events that legitimately invalidate old KV.

Idle prewarm cannot cover the first four because it reconstructs weights only after the new process starts. Persisted KV can complement prewarm by avoiding repeated prefix prefill after the exact same model is resident again.

### 1.4 Workload exposure

| Workload | Typical prompt | Current restart behavior | Persistence opportunity |
|---|---:|---|---|
| Single-turn buyer | 1–4k tokens | Full prefill on every request regardless | Low unless prompts repeat under one conversation key |
| Multi-turn chat | 4–32k and growing | In-process LCP reuse; full surviving prefix lost on restart | High when the conversation resumes after deploy/crash/reboot |
| Coding agent | 8–64k system, tools, and history | Large repeated prefix; restart destroys all in-RAM layers | Highest plausible benefit, but also largest disk footprint |

The avoided work is the reusable LCP, not the whole prompt unconditionally. Short single-turn traffic may see no benefit because FR-CI2 requires an LCP of at least 32 tokens and a proper prefix shorter than the incoming prompt.

### 1.5 Directional economic exposure

SPEC-005 v0.6 is the billing arithmetic and eligibility authority; its *default* is that an unconfigured `prompt_cache_hit_credits_per_mtok` bills cached tokens at the **full prompt rate** (no discount). The specific numbers here come from the **deployed** Qwen rate card in [`phase4-coordinator/dist/coordinator.yaml`](../../phase4-coordinator/dist/coordinator.yaml), which sets `prompt_credits_per_mtok: 117500` (`$0.1175/M`) and `prompt_cache_hit_credits_per_mtok: 29375` (`$0.029375/M`). The directional discount lost when one million otherwise eligible cached prompt tokens must be recomputed is therefore, for that deployed card: `$0.1175 - $0.029375 = $0.088125 per million tokens`.
This is an opportunity-cost lens, not a proposed price or settlement change. Billing remains: `uncached_prompt_tokens = prompt_tokens - cached_prompt_tokens`.
Positive cached-token billing remains eligible only under SPEC-005 §5.3.1's sticky-hit, attempt-zero, valid-result gates, whose canonical isolation cross-checks remain in SPEC-024 §14. Persisting KV does not entitle a provider to report more cached tokens; the provider must still prove an exact eligible LCP under the shipped predicate.

---

## 2. Shipped baseline and brownfield evidence

### 2.1 `ConversationCache` today

[`ConversationCache.swift`](../../phase3-binary/Sources/malibu-cli/ConversationCache.swift) is an actor-backed, process-wide store of token sequences and `[KVCache]` layers. Its default limits are:

- eight conversation entries;
- 200,000 total tokens;
- a 15-minute TTL; and
- a 32-token LCP threshold.

`begin()` trims the incoming `conversation_key`, lazily sweeps expired entries, validates model and KV settings, computes an exact token LCP, and trims every cache layer.
Any non-trimmable layer or non-exact trim becomes a miss. `commit()` stores the completed token sequence and cache layers, then applies LRU eviction by conversation count and token count.
Process exit discards the entire store.

### 2.2 The reuse mechanism is already proven

The `origin/spike/kv-cache-hit-detection` work at commit [`84e50c92`](https://github.com/Augustas11/macprovider/commit/84e50c92) demonstrated correct multi-turn output on local Llama-3.1-8B-4bit. Turn two reported `cached_prompt_tokens=57` and traced `SPIKE conv_cache HIT lcp=57 trim_by=12`. The Jupiter-to-Io continuation demonstrated that the restored KV carried conversational context rather than producing superficially plausible garbage. Commit [`fcf7735e`](https://github.com/Augustas11/macprovider/commit/fcf7735e) staged the implementation handoff that became the SPEC-024 payoff slice. Approaches A and B therefore build on a proven lookup-and-trim path rather than a greenfield cache design.

### 2.3 Three inherited correctness traps

The spike documented three requirements that must become persistence-format tests:

1. **Tokenizer non-canonicity:** naive strict-prefix token matching failed across turn rendering; exact token LCP plus trim is the correct mechanism.
2. **Full prompt accounting:** `prompt_tokens` must remain the full incoming prompt length, not the iterator suffix, or the cached-token billing constraint breaks.
3. **Priming offset:** `mlx-swift-lm` `prepare()` / `step()` priming exposed a `cache_offset` off-by-one hazard.

Persistence adds a fourth trap: a state file can deserialize successfully while still belonging to an incompatible cache class, tensor shape, quantization mode, tokenizer/template, or model revision. Deserialization success is not reuse eligibility.

### 2.4 Current upstream state surface

The repository pins `mlx-swift-lm` 3.31.4 at revision `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`. Its public [`KVCache` interfaces](https://github.com/ml-explore/mlx-swift-lm/blob/bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57/Libraries/MLXLMCommon/KVCache.swift) expose array state and metadata, plus trim/copy behavior. Quantized cache variants also carry group size, bit width, mode, and quantized key/value tuples. That surface makes an experimental serializer feasible. It does not promise a stable cross-version on-disk ABI, so the macprovider envelope must pin and validate its own format and dependency identities.

---

## 3. Landscape audit

### 3.1 Comparison

| System | Persistence model and format | Invalidation / isolation | License | Maturity judgment |
|---|---|---|---|---|
| [oMLX](https://github.com/jundot/omlx) | Paged hot RAM plus cold SSD; safetensors blocks; matching prefixes can be restored after restart | Model/cache metadata around a paged manager; its local-server boundary is not macprovider's FR-CI5–CI10 boundary | Apache-2.0 | Active and useful as an observe-only architecture reference; its absolute TTFT claim is unreplicated marketing |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | CLI can explicitly save/load prompt caches as safetensors; `mlx_lm.server` request caching is an in-memory LRU | Explicit cache files rely on caller/model metadata; server cache does not automatically survive process exit | MIT | Mature upstream primitives, but no production automatic restart tier matching this requirement |
| [vllm-mlx](https://github.com/waybarrios/vllm-mlx) | Paged KV, prefix caching, and an advertised `--ssd-cache-dir` cold tier | Project-defined paging metadata; macprovider isolation and billing gates would still need an adapter | Apache-2.0 | Fast-moving 2026 project; relevant reference, not locally validated |
| [llama.cpp server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) | Binary slot save/restore/erase through `--slot-save-path` and `/slots/{id}` actions | Manual slot/model lifecycle; no account-scoped opaque-key policy equivalent | MIT | Mature proof that explicit process-state cache files are operable, but different runtime and trust model |
| [LM Studio mlx-engine](https://lmstudio.ai/blog/mlx-engine-agentic-workloads) | Disk-backed 256-token checkpoints in safetensors blobs within a scratch file | `/tmp` scratch and model-lifetime lookup metadata are cleared on unload/process exit | MIT engine | Validates disk checkpoint mechanics, not restart survival |
| [Ollama](https://github.com/ollama/ollama) | Documented KV type, keep-alive, and multi-user cache controls; no official durable restart-cache contract found | Observable cache lifetime is tied to loaded runners/process state | MIT | Mature serving product, but not evidence for this feature |
| [colibri](https://github.com/JustVugg/colibri) | Append-per-turn `.coli_kv`; startup resume without re-prefill; crash-safe mechanism | Single-user local model; no macprovider invalidation, account isolation, purge, or receipt boundary | Apache-2.0 | Legally inspectable, useful mechanism prior art, but very young and not a policy template |
| macprovider | In-RAM `[KVCache]` per trimmed `conversation_key`; exact LCP plus trim | SPEC-024 §11–16, TTL/LRU, model ID and `kvBits` checks | Internal | Correct in-process brownfield baseline; no restart survival |

### 3.2 What oMLX contributes—and does not

oMLX demonstrates a coherent hot/cold architecture:

- block-based KV allocation;
- hot RAM ownership;
- write-back to SSD;
- safetensors cold blocks; and
- prefix restoration after server restart.

Those are portable patterns. Its runtime is explicitly out of scope, and macprovider must not adopt it as the inference engine in this work. Its “30–90 s to under 5 s” statement remains **oMLX marketing, unreplicated by RESEARCH_234**. No decision or threshold in this memo treats that range as measured macprovider performance.

### 3.3 mlx-lm nuance

It would be inaccurate to say mlx-lm has no disk cache capability. The CLI can serialize a prompt cache to safetensors and later load it. The automatic HTTP server path, however, uses a process-memory LRU and does not provide macprovider's required restart-aware, account-scoped disk tier. The distinction supports Approach A: use upstream state surfaces, while macprovider owns admission, indexing, invalidation, isolation, quotas, and lifecycle.

### 3.4 colibri's mechanism and the bytes-per-token caveat

colibri validates append-per-turn persistence and startup resume in an Apache-2.0 codebase. Its published roughly 182 KB/token figure is for GLM's MLA-compressed KV with 576 floats per token. It must not be transferred to the live Qwen model. The live [`Qwen3-Coder-30B-A3B-Instruct-4bit` configuration](https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit/blob/main/config.json) is GQA/MoE with:

- 48 hidden layers;
- 4 key/value heads;
- 128 dimensions per head; and
- 32 attention heads.

For a hypothetical 4-bit KV cache with group size 64, using 0.5 byte per scalar plus 8 bytes of scale/bias metadata per 64 values, the estimate is: `2 × 48 × 4 × 128 × (0.5 + 8/64) = 30,720 bytes/token`.
That is approximately 30 KiB/token:

| Prefix | Estimated q4 KV payload | Excludes |
|---:|---:|---|
| 8k tokens | 234 MiB | framing, checksums, token IDs, filesystem overhead |
| 32k tokens | 938 MiB | same |
| 64k tokens | 1.88 GiB | same |

For comparison, FP16 K+V at the same GQA shape is 98,304 bytes/token, or 96 KiB/token. The model's 4-bit **weight** quantization does not establish that its runtime KV is 4-bit. Any q4 persistence proposal must first establish the active `kvBits`, quantify quality/performance, and invalidate on every bit-width, group-size, or mode change.

---

## 4. Design options

### 4.1 Summary

All TTFT outcomes in this table are hypotheses until KVS-01 produces usable controlled samples.

| ID | Approach | Engineering estimate | Restart TTFT expectation | Resource profile | Decision |
|---|---|---:|---|---|---|
| A | Extend `ConversationCache` with a disk tier | 2–4 engineer-months | **KVS hypothesis:** p50 ≤ `max(1.25× warm, warm+1 s)` and p95 ≤ `max(1.5× warm, warm+2 s)`; cold-relative reduction unknown | 0.23–1.88 GiB per 8k–64k q4 conversation, bounded staging RAM | Primary |
| B | Prefix-hash token store plus rehydrate | 1–2 engineer-months | On-demand p50/p95 should resemble E; eager post-readiness latency may approach warm only after shifting the full prefill into startup | Tiny token store, but reconstructs full RAM KV and consumes compute | Prototype/control only |
| C | Upstream `mlx-swift-lm` paged/save-load API | 1–3 engineer-months contribution; 3–6 months calendar uncertainty | **KVS hypothesis:** same normalized p50/p95 targets as A if upstream state is restart-stable; absolute seconds unknown | Depends on upstream layout; likely block-oriented | Fallback |
| D | External sidecar using an oMLX-compatible concept | 3–6 engineer-months | No defensible local p50/p95 forecast; oMLX's absolute claim remains unreplicated marketing | Duplicate process/runtime surface; SSD plus IPC and memory pressure | No-go for first implementation |
| E | Do nothing beyond RAM cache and prewarm | Near zero | **Known semantics:** p50 and p95 restart KV reduction are both 0% | No new disk; full prefix re-prefill after exit | Control / accepted fallback state |

Compatibility constraints are also approach-specific:

| ID | `kvBits` | Warm-swap | Speculative decode |
|---|---|---|---|
| A | Exact bit width, group size, and mode in every block; mismatch is a miss | Exact full identity only; otherwise invalidate | Excluded from the first format and cache path |
| B | Rehydrate under the current setting only; stored metadata must match | Replay only after exact model/tokenizer validation | Separate cache path; no ordinary-cache credit |
| C | Upstream API must expose quantization/cache-class metadata | Macprovider still enforces exact identity | Unsupported until upstream and macprovider define an explicit safe path |
| D | Sidecar API must carry the full setting; omission makes the design unacceptable | Namespace must rotate on every incompatible swap | Do not mix sidecar ordinary KV with speculative state |
| E | Shipped same-`kvBits` predicate | Current process state is lost or misses on mismatch | Shipped behavior reports zero reuse |

### 4.2 Approach A — disk tier behind `ConversationCache`

Approach A keeps the current actor as the policy owner and adds a cold store under a provider-private cache directory. Recommended logical architecture: ```text
coordinator request
        |
        v derived opaque conv: key
        |
        v
+---------------- ConversationCache policy ----------------+

| FR-CI checks | exact LCP | model/KV identity | TTL/LRU  |
+---------------+----------------------+--------------------+
                | RAM hit              | RAM miss
                v                      v
        hot [KVCache] layers     encrypted disk index
                                       |
                                       v
                              validate sealed manifest
                                       |
                              miss <---+---> stream/restore
                                                  |
                                                  v
                                         exact trim + promote
                                                  |
                                                  v
                                         suffix prefill/decode ```
The disk entry should be an opaque, versioned envelope rather than a raw dump with an implied Swift ABI. Minimum header and associated-data fields:

- format magic and schema version;
- provider namespace and cache-key epoch;
- HMAC-derived index of the opaque `conversation_key`, not the raw key as a filename;
- model ID, exact `model_sha256`, and catalog revision;
- tokenizer and chat-template identity;
- MLX and `mlx-swift-lm` build/API identity;
- cache implementation class and layer count;
- tensor shapes, dtypes, and layout version;
- `kvBits`, group size, and quantization mode;
- token count and block sequence number;
- creation, last-eligibility, and expiry times; and
- payload length, checksum, and AEAD authentication data.

The encrypted payload contains the token sequence needed for LCP plus the per-layer cache arrays and metadata. Writes occur only after a successful request commit. Use append-only data blocks with an fsync-and-atomic-rename manifest or a small journal so a crash yields either the old committed generation or a miss. Never accept a partially appended generation. Reads validate metadata and expiry before allocating large arrays. Promotion should stream or memory-map bounded blocks and obey the existing RAM token cap; it must not double the live model's roughly 32 GB resident footprint. Disk eviction should be per provider and per conversation count/token/byte budget. Do not introduce global content-addressed block deduplication across conversation keys or provider identities.

### 4.3 Approach B — prefix hash plus token replay

Approach B stores canonical prompt tokens and metadata, then regenerates KV by prefill under the current model. Its disk footprint is far smaller than serialized activations. It also avoids accepting stale activations because every cache is recomputed by current weights after validation. However, it does not remove prefill work. On-demand replay moves no latency out of the request path. Eager replay moves the same compute into startup and can delay readiness, heat the 32 GB production Mac, contend with live requests, and recreate a large in-RAM cache before demand is known. It is useful as:

- a correctness oracle for A;
- a format-recovery fallback when activation ABI changes;
- a benchmark control; or
- a narrowly capped background rehydrate experiment.

It is not the production answer to restart TTFT. It also stores directly decodable token IDs, making prompt recovery simpler than from activation tensors.

### 4.4 Approach C — upstream portable primitives

Approach C contributes a stable save/load or paged cold-tier interface to `mlx-swift-lm` and wraps it with macprovider policy. This is the best fallback if direct array serialization proves brittle or future batching requires a shared allocator. The advantage is upstream ownership of model-specific cache subclasses and tensor layout changes. The cost is calendar uncertainty and the risk that an upstream API solves serialization but not crash consistency, quotas, account isolation, provider purge, or billing eligibility. Macprovider still owns all SPEC-024 and SPEC-005 gates.

### 4.5 Approach D — external sidecar

A sidecar can centralize disk blocks and survive provider-process relaunches. It also creates a second privileged process that receives conversation identifiers or their derivatives, reads activation data, manages model-format compatibility, and can create cross-provider contention. IPC copying or shared-memory coordination adds latency and memory complexity on an already saturated host. An “oMLX-compatible” format is not a stable public contract and would couple macprovider to an out-of-scope runtime architecture. This option should not be pursued before A/C prove impossible.

### 4.6 Approach E — retain the current behavior

Approach E is safe and operationally simple. It preserves the measured 4.2% over-20-second tail exposure and accepts full re-prefill after process loss. It remains the correct control during KVS benchmarking and the fallback if no disk design clears correctness, isolation, purge, and RAM gates.

---

## 5. Security, isolation, billing, and attestation

### 5.1 Load-bearing shipped invariants

SPEC-024 v0.2.1 §11–16 is the provider-local cache-isolation authority. The implementation must preserve these facts rather than replace them with a new persistence-specific interpretation.

**FR-CI1 — partition.** `ConversationCache` is keyed only by the trimmed `conversation_key` string. There is no account, buyer, or provider-identity component in the in-memory key. A lookup for K must never return, reuse, or measure a prefix stored under K′.

**FR-CI2 — reuse predicate.** Reuse is only the exact token-level LCP, with LCP at least 32 and shorter than the incoming prompt, identical model ID, and identical `kvBits`. Every KV layer must be trimmable, and every trim must remove exactly the requested count. Any mismatch is a miss, never partial or best-effort reuse.

**FR-CI4 — lifecycle.** Eligibility uses a default 900-second TTL plus LRU on conversation and token caps. The TTL sweep is lazy and runs on the next `begin()`. An idle process may physically retain expired KV beyond TTL even today. A disk tier makes that retention durable and forensically recoverable, so TTL must be described as an eligibility deadline, not a guaranteed erasure time.

**FR-CI5/CI6 — cross-account trust dependency.** The provider must receive an account-scoped, unforgeable key: `conv:` + `base64url_unpadded(HMAC-SHA256(secret, scope + "\n" + account_id + "\n" + tag))`.

If this holds, key-only partitioning is sufficient for cross-account lookup isolation. If it fails, `cached_prompt_tokens` and TTFT become an LCP-granularity prefix-match oracle. Persistence does not create that dependency, but extends the blast radius across restart and, on a shared Mac, across processes.

**FR-CI8 — capacity channel.** The shipped process-wide store has global caps, so one key can evict another key's warm state. This reveals no prompt content, but it is a real latency and discount-denial channel. A shared on-disk pool can turn it into a cross-process channel unless namespaces and quotas are per provider.

**Provider visibility and purge.** The provider legitimately sees the derived opaque `conv:` key and is trusted to hold but not exfiltrate it. `DELETE /v1/sticky` removes only the coordinator sticky map; it does not purge the provider's local entry. Disk persistence worsens this gap because the entry survives restart. A provider-side, conversation-key-scoped purge primitive, including a durable tombstone that prevents resurrection from an old manifest, is a prerequisite to production use.

### 5.2 Required five-by-five threat table

| Threat | A — disk tier | B — token rehydrate | C — upstream primitive | D — sidecar | E — RAM only |
|---|---|---|---|---|---|
| Stale cache after `model_sha256` change | Hard miss before payload load; purge/tombstone all old generations. Exact hash is mandatory even if model ID is unchanged. | Reject stored tokens/metadata for the old model/template; any rehydrate uses current weights only after validation. | Upstream loader must expose exact identity; macprovider rejects or purges on hash mismatch. | Sidecar namespace and API must include exact hash; failure or omission is a hard miss and makes D unacceptable. | No restart-durable stale state; current in-process model-ID/`kvBits` checks remain, but exact hash should govern any warm-swap boundary. |
| Cross-provider leakage on a shared Mac | Separate UID/provider namespace, per-provider index HMAC/AEAD key, quota, and no global dedup; FR-CI5/CI6 still mandatory. | Same namespace rules; plaintext-equivalent token content makes a namespace failure especially direct. | Same policy envelope is required regardless of upstream block format. | Highest structural risk: central process can see multiple providers; require mutually authenticated namespaces and per-provider keys/quotas, otherwise no-go. | Limited to the current process, but key collision and global capacity contention remain within it. |
| Prompt-prefix recovery from disk | Activation tensors and token lists are sensitive; encrypt/authenticate, use `0700` directory/`0600` files, best-effort unlink, and key-epoch destruction. Never promise physical erasure at TTL. | Worst recovery profile: token IDs reconstruct prompt text directly. Encrypt identically; prefer not to ship this as the production store. | Treat upstream files as secret regardless of format; wrap or require encryption and macprovider lifecycle controls. | Sidecar files and IPC enlarge the forensic surface; encryption at rest does not protect a compromised running sidecar. | No intentional disk tier, though lazy TTL means RAM can outlive eligibility and OS swap/core artifacts remain outside the cache guarantee. |
| Coordinator receipt mismatch | None permitted: provider reports existing `cached_prompt_tokens`; SPEC-005 computes billing; locked SPEC-015 receipts are unchanged. | Same. Rehydrate is not billable reuse until exact current-request LCP is actually reused. | Same; upstream metadata cannot create a new billing fact. | Same, but sidecar hits must pass the provider's existing eligibility gates before reporting. | Existing contract only. |
| OPoI drift false positives | Corrupt/stale blocks could change probe output or latency; bypass persistence for probes or bind exact model hash and treat every anomaly as cache miss. Never escalate cache corruption into sanction. | Corrupt tokens can change the probe input; authenticate and preferably bypass. Current-weight replay reduces stale-activation risk. | Require the same bypass/hash/miss behavior from the upstream adapter. | Extra IPC/cache faults can mimic model drift; isolate probes and keep alerts observational. | No new durable-cache risk; SPEC-032 remains telemetry-only and hash mismatch remains a separate route exclusion. |

### 5.3 Mandatory invalidation rules

Every persisted candidate is ineligible and should be tombstoned or asynchronously purged when any of the following changes or cannot be proven:

1. exact `model_sha256`;
2. model ID or provider catalog revision;
3. tokenizer identity, tokenizer configuration, or chat-template hash;
4. `kvBits`, quantization group size, quantization mode, or cache quantization policy;
5. cache implementation class, layer count, tensor shape, dtype, or layout version;
6. MLX / `mlx-swift-lm` compatibility epoch used by the format;
7. speculative-decoding versus ordinary-decoding cache path;
8. provider namespace, provider identity, cache encryption key epoch, or HMAC indexing key;
9. conversation purge generation or revocation tombstone;
10. TTL eligibility deadline;
11. AEAD tag, checksum, block sequence, manifest generation, or payload length;
12. atomic-commit status after a crash or partial write; or
13. any trim that is unsupported or does not remove exactly the requested token count.

A warm-swap to the same model family is still a miss unless every exact identity above matches. Family similarity, filename similarity, and catalog aliases are not sufficient. Expired blocks may remain physically present until compaction, unlink, quota eviction, or key rotation, but they must never be eligible for reuse.

### 5.4 Disk confidentiality limits

File permissions and FileVault reduce exposure to other host users and offline disk theft. AEAD with a per-provider installation key prevents accidental parsing, cross-namespace reads, and undetected modification. Neither protects against a compromised provider process that can ask Keychain for its live key. The design should therefore minimize durable content, cap retention, avoid raw conversation keys in paths, and make purge auditable. Encryption is a necessary control, not a claim that activation data is non-sensitive.

### 5.5 Receipt and attestation verdict

**Verdict: provider-local-only; no new attestation or receipt field for the MVP.** Persistent KV is a performance optimization beneath the existing inference result. `cached_prompt_tokens` already has its wire home in SPEC-024 §3 and its billing arithmetic in SPEC-005 v0.6.
SPEC-024 §11–16 supplies the isolation and eligibility invariants. SPEC-015 v0.4.2 is the locked settlement-capable receipt profile for SPEC-022. The persistence work must not retrofit cache hashes, block IDs, storage provenance, or KV metadata into that receipt. `model_hash` remains an invalidation input and existing model identity fact; it does not attest the integrity of cached activations.
If a future buyer-facing guarantee requires binding cache provenance or persisted-state identity, the normative question is explicitly deferred to a future **SPEC-015 v0.5** discussion. That question is not answered by, and must not modify, the locked v0.4.2 profile in this work.

### 5.6 OPoI boundary

SPEC-032's proof-of-identity nonce is observability-only. It must not affect routing, sanctions, payout, or settlement. The safest initial rule is to bypass persisted KV for OPoI probes. If probes later use persistence, exact model identity, authenticated block integrity, and fail-as-miss behavior are mandatory. A cache restore failure may emit cache-health telemetry; it must not be reported as model drift or provider fraud.

---

## 6. Idle prewarm and memory budgets

Idle prewarm lives in the provider CLI, not SPEC-017. [`Config.swift`](../../phase3-binary/Sources/MacProviderCore/Config.swift) exposes:

| Setting | Default |
|---|---:|
| `idlePrewarmEnabled` | `true` |
| `idlePrewarmIdleThresholdSeconds` | `30` |
| `idlePrewarmTickSeconds` | `5` |
| `idlePrewarmMaxTokens` | `1` |
| `idlePrewarmPrompt` | `"warm"` |
| `idlePrewarmRunOnBattery` | `false` |

Commit [`ed2f782`](https://github.com/Augustas11/macprovider/commit/ed2f782) added best-effort visibility for this path. That telemetry is non-critical and must not influence billing, routing, or settlement. RESEARCH_234 observed approximately 54,000 `idle_prewarm_skipped` events, showing tick-cadence log spam rather than useful per-event business telemetry. Separately, the buyer-runner's five-minute request cadence is a de-facto prewarm in production. The two optimizations compose:

- idle prewarm or real traffic keeps **weights** resident;
- persisted KV restores a reusable **prompt prefix**; and
- suffix prefill plus decode completes the request.

The live model already occupies roughly the entire 32 GB memory class. Approach A must not retain a second unbounded copy of restored tensors while materializing them. Required implementation constraints include:

- bounded block reads or mappings;
- promotion directly into the hot cache representation where possible;
- adherence to the existing 200k-token RAM budget;
- back-pressure rather than parallel bulk restores;
- no eager restoration of every disk conversation at startup; and
- disk LRU independent of RAM promotion.

The disk tier trades SSD capacity for avoided prefill; it is not permission to raise the hot-cache RAM ceiling without a separate memory study.

---

## 7. Sequencing with RESEARCH_232 batching

### 7.1 Shared concern

True continuous batching and paged KV persistence can share:

- fixed-size block geometry;
- ownership and reference counting;
- copy-on-write prefix sharing;
- eviction metadata;
- block serialization; and
- GPU/unified-memory placement decisions.

RESEARCH_232 also distinguishes true shared scheduling from the current semaphore-like concurrency path. Building a new paged allocator solely for persistence would prematurely decide the batching architecture.

### 7.2 Explicit recommendation

**Sequence persistence first, conditionally, because the first TTFT experiment is independent of a shared paged-KV layout.** Approach A can serialize each current per-conversation `[KVCache]` layer state as an opaque versioned record and restore it through the already-proven exact-LCP/trim mechanism. That experiment answers whether restart survival has sufficient value without waiting for multistream batching. It should not introduce copy-on-write blocks, cross-request sharing, or a new attention allocator. Use a codec/version boundary so a later paged layout can add a new storage representation without pretending old blocks are compatible.

### 7.3 Pivot gate

If KVS-01 shows that contiguous restore cannot meet the relative warm-baseline threshold because:

- tensor reconstruction dominates TTFT;
- the format requires full-copy materialization;
- RAM peaks are unsafe; or
- `mlx-swift-lm` cannot restore current cache subclasses reliably,

then stop the direct serializer. Sequence the shared paged-KV/batching design first, preferably through Approach C, and make persistence a consumer of that block layout. This avoids two incompatible allocators while still obtaining early evidence.

### 7.4 What can proceed in parallel conceptually

The following persistence policy work is layout-independent and reusable after any pivot:

- provider/account namespace analysis;
- purge semantics;
- exact invalidation identity;
- AEAD key lifecycle;
- crash-consistent manifests;
- disk quotas and capacity-channel controls;
- metrics; and
- KVS harness scenarios.

No batching implementation is part of this research turn.

---

## 8. Future benchmark plan

Use the merged [`test/e2e/coldwarm-ttft/`](../../test/e2e/coldwarm-ttft/README.md) harness and its `run-coldwarm.sh --build-matrix` path. Do not build a parallel cold/warm harness. Because the current Mac is production, controlled kill/reboot tests require a maintenance window or a separate equivalent host. All runs must record regime labels, prompt/input hashes, model ID/hash, catalog revision, `kvBits`, cache format version, hit/miss reason, full prompt tokens, cached prompt tokens, TTFT, total latency, disk bytes read/written, peak RSS, and correctness outcome.

### KVS-01 — restart survival on an 8k prefix

**Scenario:** Send an 8k-prefix request to completion, persist, kill the provider process, relaunch the exact build/model, and repeat with a suffix. **Controls:** in-RAM warm repeat, clean cold restart, Approach B replay, and disk-disabled provider. **Primary metric:** TTFT p50/p95 over enough cycles for stable tails. **Correctness gates:**

- output passes the same multi-turn semantic fixture as the Jupiter-to-Io spike;
- exact expected LCP is reported in `cached_prompt_tokens`;
- full incoming length remains `prompt_tokens`;
- all layers trim exactly; and
- any corrupted block becomes a miss with correct output.

**Performance gate:** restored p50 no worse than `max(1.25 × warm p50, warm p50 + 1 s)` and restored p95 no worse than `max(1.5 × warm p95, warm p95 + 2 s)`. Once a usable cold control exists, require at least a 30% p95 TTFT reduction versus that control. These are **KVS acceptance hypotheses**, not RESEARCH_234 measurements.

### KVS-02 — warm-swap same family

**Scenario:** Persist under one model revision, warm-swap to another model in the same family, then issue a matching conversation request. **Gate:** deterministic miss, `cached_prompt_tokens=0`, no old payload promotion, correct fresh output, and an explicit invalidation reason. If the exact model hash and every compatibility identity are unchanged, a process relaunch is KVS-01 rather than a warm-swap invalidation case.

### KVS-03 — `model_sha256` change

**Scenario:** Change only the exact model hash while keeping a tempting model ID/alias, then request the old prefix. **Gate:** zero disk hits from the old generation, full invalidation/tombstone recorded, no stale payload read into model memory, and fresh correct output. Repeat for tokenizer/template, `kvBits`, group size, cache-layout epoch, and truncated/corrupt manifest variants.

### KVS-04 — 24-hour disk and memory budget

**Scenario:** Run representative conversations for 24 hours on an M4 Max 64 GB test host, including 8k, 32k, and 64k prefixes, expiries, evictions, and restarts. **Metrics:** disk high-water mark, write amplification, compaction time, restore bytes, cache-hit yield, peak RSS, swap, and cross-key eviction. **Gates:**

- enforce an initial 16 GiB provider-local disk cap;
- remain within 20% of the model-derived payload estimate after recorded framing/compression effects;
- no unbounded growth after TTL expiry and compaction;
- no cross-provider eviction under separate namespaces; and
- restore staging adds no more than 256 MiB peak RSS beyond the selected hot-cache state.

The 16 GiB cap is an initial operational guardrail, not a normative protocol value.

### KVS-05 — idle prewarm plus persisted KV

**Scenario:** Exercise weights-prewarmed/KV-restored, weights-prewarmed/KV-miss, and fully cold controls after an idle interval. **Metrics:** TTFT, time to readiness, model RSS, restore staging RSS, swap pressure, and prewarm/cache telemetry volume. **Gates:**

- restored p50 meets the KVS-01 warm-relative gate;
- no provider crash, jetsam-like termination, or sustained swap growth;
- persistence does not alter prewarm billing/routing/settlement behavior;
- skipped-prewarm logging is rate-limited or aggregated; and
- disk restore never triggers eager all-conversation promotion.

### Cross-scenario security tests

Every KVS scenario should also attempt:

- another provider namespace reading the file;
- a forged or collided conversation tag;
- a raw file copied into a different provider directory;
- replay of a pre-purge manifest;
- process death between data append and manifest commit;
- wrong AEAD key epoch;
- TTL-expired but physically present data;
- disk-full and read-only-filesystem failures; and
- maliciously oversized length/shape metadata.

All failures must be bounded, observable, and fail as cache misses unless the local store itself must be quarantined.

---

## 9. Recommendation, fallback, and no-go list

### 9.1 Primary — Approach A

Proceed to a future BUILD_SPEC for an encrypted, provider-namespaced cold tier behind `ConversationCache`, contingent on a safe benchmark host/window and provider-side purge design. The MVP should be deliberately narrow:

- one exact model hash at a time;
- ordinary decode only;
- no cross-conversation block sharing;
- no cross-provider service;
- existing LCP/trim semantics;
- lazy on-demand restore;
- versioned opaque layer serialization;
- append-only crash-consistent generations;
- strict miss-on-ambiguity validation;
- 16 GiB initial disk cap; and
- current RAM token cap with 256 MiB restore staging ceiling.

This gives the shortest path to a decision-grade KVS-01 result while preserving an exit to paged KV later.

### 9.2 Fallback — Approach C

If direct serialization is unstable across supported cache classes or cannot meet memory/latency gates, contribute or wait for a portable `mlx-swift-lm` save/load/paging interface. Retain macprovider ownership of keys, invalidation, encryption, quotas, purge, telemetry, and billing eligibility. Do not interpret an upstream format as an upstream trust policy.

### 9.3 No-go list

Do not pursue:

1. adopting oMLX as macprovider's inference engine for this feature;
2. using d-inference source or implementation details—the clean-room boundary remains absolute;
3. a central multi-provider sidecar before A/C are disproven;
4. global content-addressed deduplication across conversation keys, accounts, or providers;
5. plaintext token files as the production persistence format;
6. reuse based on model family, filename, alias, or catalog name without exact hash;
7. best-effort deserialization followed by partial layer reuse;
8. counting startup rehydrate compute as eliminated prefill;
9. raising the RAM cache budget merely because disk persistence exists;
10. claiming physical erasure at TTL under the lazy-sweep lifecycle;
11. shipping without provider-side conversation purge and anti-resurrection tombstones;
12. adding persistence fields to locked SPEC-015 v0.4.2 receipts; or
13. treating oMLX's marketing numbers as macprovider performance evidence.

---

## 10. Quarterly milestones and gates

### 2026 Q3 — format and measurement readiness

- Write a future BUILD_SPEC defining the disk envelope, invalidation matrix, namespace, crypto/key lifecycle, purge semantics, quotas, and failure telemetry.
- Establish a non-production M5/M4-class host or approved maintenance window.
- Repair/populate the RESEARCH_234 cold/warm sample regimes using the existing build matrix.
- Build an offline round-trip serializer prototype against the pinned `mlx-swift-lm` cache classes.
- Gate: corrupt/wrong-version inputs fail closed; no runtime rollout.

### 2026 Q4 — narrow restart prototype

- Implement Approach A behind a disabled-by-default experimental flag in a future implementation session.
- Run KVS-01, KVS-02, and KVS-03 across exact model, model swap, hash change, tokenizer change, `kvBits` change, crash-mid-write, and purge replay.
- Gate: all correctness/security cases pass and KVS-01 meets the warm-relative threshold.
- Pivot to Approach C / shared paged layout if restore materialization misses latency or RAM gates.

### 2027 Q1 — bounded operational soak

- Add per-provider disk quota, compaction, metrics, AEAD key rotation, tombstones, and provider-local purge propagation.
- Run KVS-04 for 24 hours on a 64 GB test host and a reduced-capacity safety run on an equivalent 32 GB host.
- Gate: disk stays bounded, staging RSS stays within 256 MiB, no cross-provider eviction/read, and crash recovery produces only committed generations.

### 2027 Q2 — prewarm composition and limited canary

- Run KVS-05 with weights-only prewarm, KV-only restore, combined mode, and cold controls.
- Rate-limit or aggregate `idle_prewarm_skipped` telemetry as an operational follow-up, without connecting it to billing/routing/settlement.
- Canary only on provider-owned synthetic conversation keys and non-settlement-sensitive traffic.
- Gate: warm-relative TTFT target, no memory instability, and no receipt/wire changes.

### 2027 Q3 — batching compatibility decision

- Compare the proven contiguous format with RESEARCH_232's selected scheduler/KV layout.
- If continuous batching adopts paged KV, design a new codec version rather than mutating old block interpretation.
- Re-run KVS-01–05 under the batching layout.
- Gate: no regression in isolation, hit accounting, correctness, or memory ceilings.

### 2027 Q4 — production decision

- Review measured hit rate, restored TTFT distribution, SSD write volume, purge compliance, operational incidents, and avoided billable-prefill opportunity cost.
- Decide among general rollout, limited long-context rollout, upstream-only continuation, or Approach E.
- Gate: every KVS scenario passes on the release build and no unresolved high-severity isolation or recovery finding remains.

---

## 11. Open questions for the future BUILD_SPEC

1. Which supported `KVCache` subclasses can be reconstructed without private upstream state?
2. Is safetensors adequate for atomic block append, or should data blobs and the manifest use separate formats?
3. Should per-provider encryption keys live in Keychain, and what is the unattended supervisor access policy?
4. How does a coordinator sticky deletion propagate a signed provider-local purge without adding a buyer-visible cache API?
5. What is the retention policy when TTL eligibility expires but physical compaction is delayed?
6. Is the active production KV representation FP16, q8, q4, or model-specific for each catalog entry?
7. Can q4 KV meet output-quality and restore-time gates for the live Qwen model?
8. Which model/catalog revision field is stable enough to combine with exact `model_sha256`?
9. Should OPoI always bypass both hot and cold conversation caches?
10. What cache-health events are safe to export without creating a new prefix oracle?
11. What is the correct per-provider disk budget on 256 GB, 512 GB, and larger SSD classes?
12. Can compaction provide bounded best-effort deletion without claiming secure physical erasure?
13. How are old encryption-key epochs destroyed after a bulk purge or provider removal?
14. Does a future shared paged allocator expose copy-free restore into unified memory?
15. Does buyer-facing persisted-cache provenance ever justify a future SPEC-015 v0.5 field?

The answer to question 15 is deliberately deferred. It does not reopen or modify SPEC-015 v0.4.2.

---

## 12. Source and authority map

### Normative repository sources

- [SPEC-005 v0.6 — metering and billing](../../specs/SPEC-005-billing.md): ledger schema, rate-card keys, arithmetic, and billing eligibility.
- [SPEC-024 v0.2.1 — prefix cache wire, fraud, and isolation](../../specs/SPEC-024-prefix-cache-billing.md): `cached_prompt_tokens` wire field, buyer mirror, fraud model, and §11–16 provider-local isolation baseline.
- [SPEC-015 v0.4.2 — locked receipts](../../specs/SPEC-015-receipts.md): settlement-capable receipt contract that this proposal does not change.
- [SPEC-032 — OPoI](../../specs/SPEC-032-proof-of-weights-hello-gate.md): telemetry-only probe and its non-enforcement boundary.
- [SPEC-004](../../specs/SPEC-004-smart-router.md), [SPEC-006](../../specs/SPEC-006-buyer-api.md), and [SPEC-008](../../specs/SPEC-008-tier2.md): provider visibility of the derived opaque conversation key and model identity context.

### Repository implementation and research sources

- [`ConversationCache.swift`](../../phase3-binary/Sources/malibu-cli/ConversationCache.swift): shipped in-RAM exact-LCP reuse, lifecycle, and limits.
- [`Config.swift`](../../phase3-binary/Sources/MacProviderCore/Config.swift): real idle-prewarm surface and defaults.
- [`test/e2e/coldwarm-ttft/`](../../test/e2e/coldwarm-ttft/README.md): merged RESEARCH_234 harness to reuse for KVS scenarios.
- [RESEARCH_232 batching prompt](../../audits/_prompts/RESEARCH_232_MULTISTREAM_BATCHING_PROMPT.md): shared scheduler/paged-KV interaction.
- Commit [`84e50c92`](https://github.com/Augustas11/macprovider/commit/84e50c92): correct end-to-end LCP/trim reuse and inherited traps.
- Commit [`fcf7735e`](https://github.com/Augustas11/macprovider/commit/fcf7735e): implementation handoff.
- Commit [`ed2f782`](https://github.com/Augustas11/macprovider/commit/ed2f782): best-effort idle-prewarm telemetry.

### External primary sources

- [oMLX repository and architecture](https://github.com/jundot/omlx)
- [mlx-lm repository](https://github.com/ml-explore/mlx-lm)
- [Pinned mlx-swift-lm KV cache interface](https://github.com/ml-explore/mlx-swift-lm/blob/bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57/Libraries/MLXLMCommon/KVCache.swift)
- [vllm-mlx repository](https://github.com/waybarrios/vllm-mlx)
- [llama.cpp server slot save/restore documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [LM Studio mlx-engine disk checkpointing description](https://lmstudio.ai/blog/mlx-engine-agentic-workloads)
- [Ollama repository and configuration surface](https://github.com/ollama/ollama)
- [colibri repository and `.coli_kv` format description](https://github.com/JustVugg/colibri)
- [Live Qwen model configuration](https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit/blob/main/config.json)

---

## Final assessment

The opportunity is credible but not yet calibrated. RESEARCH_234 proves that production has a material long tail and that the current environment cannot safely manufacture the cold samples needed to price the win. The existing LCP/trim cache and spike proof remove the largest algorithmic uncertainty. The remaining risks are format stability, restore-time memory, durable-secret handling, purge semantics, and widened isolation/capacity channels. Approach A is the best next experiment because it answers the value question with the least architectural commitment. It should advance only through KVS evidence, preserve the locked billing/receipt surfaces, and pivot to upstream/shared paged KV as soon as contiguous restore proves layout-bound.
