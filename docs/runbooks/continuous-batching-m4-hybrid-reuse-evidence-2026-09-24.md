# M4 step 1: Qwen3.6 hybrid conversation-cache reuse, Studio evidence (2026-09-24)

## The problem

Before this work, no Qwen3.6 follow-up turn reused its cache on either path.

- **Serial path:** `ConversationCache.begin` required every layer to be
  trimmable. The 48 `MambaCache` recurrent layers are not trimmable, so every
  turn missed with `cache_not_trimmable`.
- **Batched path:** under `canary`, keyed first turns batch. A batched hybrid
  row retained nothing, so every follow-up was a `cold_start` miss. Round 1 of
  this e2e confirmed this:
  [`e2e-round1-batched-first-turns-retain-nothing.json`](data/cb-m4-hybrid-2026-09-24/e2e-round1-batched-first-turns-retain-nothing.json).

Every turn re-prefilled the whole conversation.

## The change

Recurrent state cannot be rewound, so reuse restores it from checkpoints:

- **Checkpoint positions (`b8486a5c`).** Snapshots are taken at two stable
  prefixes:
  - C1, the end of the system/tools scaffold;
  - C2, the start of the last turn, just before the last `<|im_start|>`.

  `begin` picks the largest checkpoint the common prefix covers. It trims the
  attention layers to that point and restores the recurrent state.
  `cached_prompt_tokens` equals the checkpoint length. SPEC-024 v0.2.5 FR-CI2.
- **Batched keyed hybrid first turns (`25767bd5`).**
  - During batched prefill, the scheduler splits prefill chunks at C1 and C2
    and snapshots the row's recurrent state there.
  - At normal terminal, the row's paged KV is materialized (FR-PKV10) and a
    serial-format entry is committed.
  - The positive-cached follow-up still serial-routes (AC-26 fence) and hits
    that entry. SPEC-038 v0.2.7.
- **Disk tier.** Hybrid entries are never disk-persisted (SPEC-037 v0.1.4).

## Rig

- **Hardware and build:** Mac Studio M3 Ultra, lab build `853a335f` from
  `campaign/1646-cb-sampling` @ `25767bd5`.
- **Relay:** buyer → loopback coordinator :19080 → a rig provider joined with
  `--isolate-lifecycle` (its own ID, credentials and HOME).
- **Provider settings:** Qwen3.6, `canary`, 4 seats, context 32768,
  `mlx_cache_limit_mb: 2048`.
- **Conversation keys:** auto-prefix style, via
  `X-MacProvider-Internal-Conv-Cache`.
- **Isolation:** the live :8080 provider was not touched.

## Results

### Reuse and first-token latency (`e2e-round2-reuse.json`, ~1.7k-token scaffold)

| Request | First token, hit | First token, miss | Cached tokens (observed) | Output vs miss |
| --- | --- | --- | --- | --- |
| Conversation A, turn 2 (C2) | **0.58 s** | 7.29 s | 1664 of 1736 | late divergence |
| Conversation B, same key, new question (C1) | **0.32 s** | 6.88 s | 1647 of 1665 | identical |
| Conversation A, turn 3 | **0.75 s** | 7.36 s | 1647 of 1801 | identical |

- **Turn 3 used C1, not C2.** Conversation B replaced the key's single entry in
  between; auto-prefix keys are shared by conversations with the same scaffold.
- **Hit vs miss divergence (3 repeats of turn 2):** one exact match; the other
  two diverge late, at char 139 of 217 and char 181 of 193. This is the
  accumulation-order tolerance from splitting prefill at a checkpoint, the same
  property existing cache-hit reuse has. A state bug would diverge at once.

### Long conversation (~15.8k tokens, `m4_stall.py`)

| Turn | Time |
| --- | --- |
| Full prefill (first turn, keyless control) | 76.6 s |
| Follow-up, hit on 15,776 cached tokens | **1.03 s** |

### Stall on other rows

A keyless background stream decoded 400 tokens while the big turn ran.

| Run | Max inter-token gap | p99 |
| --- | --- | --- |
| Keyed (checkpoints + materialize) | 2.4 s | 2.1 s |
| Keyless control (no checkpoint, no materialize) | 4.1 s | 3.2 s |

The stall comes from the existing 15.8k-token prefill interleaving with decode,
not from the new materialize step, which does not show above the prefill noise.
Prefill/decode fairness for very long prompts is a separate, pre-existing
scheduler issue.

### Billing

The flat billing field `cached_prompt_tokens` stays **0** for auto-prefix keys,
which are non-sticky and earn no discount. Observed reuse is reported in
`prompt_tokens_details.cached_tokens` (SPEC-006 R013, SPEC-024 §8). No
billing code changed.

### Memory

The footprint stayed at 18–19 GB. Each committed entry holds its attention KV
plus 2 recurrent checkpoints, bounded by the conversation cache's LRU/TTL.

## Step 2: batched cached follow-up turns (`f9a71a3b`, AC-26)

Cached follow-up turns are opt-in, behind `continuous_batching_cached_turns`
(default off, SPEC-038 v0.2.8). With the flag on, a keyed hybrid first turn
retains its paged KV plus recurrent checkpoints. The follow-up reattaches the
KV trimmed to the checkpoint, restores the recurrent state into its batched
row, prefills only the new tokens, and chains to the next turn.

Setup: rig build `f1bb870b`. Four conversations with distinct scaffolds; each
runs turn 1, then all four follow-ups run concurrently. Files:
`step2-{on,off}.json` and `step2-{on,off}-long.json`.

- **Batching:** with the flag on, all 18 requests across the runs were admitted
  to batching, the cached follow-ups included, with 0 forward failures. With the
  flag off, the follow-ups serial-route (`sticky_cache_handoff_unavailable`).
- **Checkpoint hits:** follow-ups hit the history checkpoint C2 (1258–1331
  cached tokens). Position 1260 is the assistant header of a 1267-token turn-1
  prompt.

**First-token time, 4 concurrent cached follow-ups:**

| Mode | First-token times | Worst |
| --- | --- | --- |
| Flag off (serial) | 0.63 / 3.76 / 6.58 / 9.72 s | 9.7 s |
| Flag on (batched) | 0.84 / 1.72 / 2.42 / 4.41 s | **4.4 s** |

- **Throughput:** aggregate is about 30–32 tok/s either way. These answers stop
  at around 90 tokens, so admission and prefill dominate. The scheduler admits
  one prefill per iteration (`maxPrefillRowsPerIteration`), which is a tuning
  follow-up. Batched decode throughput itself was measured at 1.41–1.86×.
- **Parity:** of 3 conversations, one is exact. The others diverge mid-answer
  at a near-tie word choice (char 72 and char 201). Both texts are coherent and
  mean the same thing. This is the FR-CB6 tolerance, not a restore fault.
- **Memory:** footprint 21 GB.

## Not yet

- **AC-26 packaged proof** before the flag goes on on a live provider: the
  relay path with receipt and settlement fields. The rig runs legacy
  settlement and cannot show receipts.
- **Codex three-lane audit** of `f9a71a3b`.
