# Codex audit: M4 step 1, Qwen3.6 hybrid conversation-cache reuse (#1646)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-cb-sampling`. Branch:
`campaign/1646-cb-sampling`. Review `git diff 3ef0825f..HEAD -- ':!docs' ':!audits'`
(commits `b8486a5c`, `25767bd5`, and the R1 fix in HEAD).

## Problem
Qwen3.6 is a hybrid model: 16 attention layers and 48 `MambaCache` recurrent
layers. Before this change it never reused its conversation cache:
- Serial path: `MambaCache` is not trimmable, so every turn missed with
  `cache_not_trimmable`.
- Batched path: keyed first turns batch under `canary`, and batched hybrid rows
  retained nothing.

## The change
- **`b8486a5c`, recurrent-state checkpoints in `ConversationCache`.**
  - Positions: C1 is the end of the system/tools scaffold (the first
    `<|im_start|>` that begins a user turn); C2 is the last `<|im_start|>`.
  - The serial path prefills up to C1 and C2 and snapshots the recurrent
    `state` there.
  - `begin` picks the largest C ≤ lcp, trims the attention layers, restores
    the recurrent state, and sets `cachedPromptTokens = C`.
  - Hybrid entries are excluded from the disk tier.
  - SPEC-024 v0.2.5 FR-CI2, SPEC-037 v0.1.4.
- **`25767bd5`, keyed batched hybrid first turns.**
  - The scheduler splits prefill chunks at C1/C2 and snapshots the row's
    recurrent state through a new backend hook.
  - At normal terminal, it materializes the row's paged KV (FR-PKV10) into
    `KVCacheSimple`, cut to the committed token count, and commits a
    serial-format entry with checkpoints.
  - The positive-cached follow-up still serial-routes (AC-26 fence unchanged)
    and hits it.
  - SPEC-038 v0.2.7.

## Studio e2e through the relay
`docs/runbooks/continuous-batching-m4-hybrid-reuse-evidence-2026-09-24.md`.
- First-token time on hits is 12–22× faster, and a 15.8k-token follow-up
  drops from 76.6 s to 1.03 s.
- Hit vs miss output is identical or diverges late (accumulation-order
  tolerance).
- The flat billing field `cached_prompt_tokens` stays 0 for auto-prefix
  (non-sticky) keys; observed reuse appears in `prompt_tokens_details`.
- Stalls on other rows come from the existing long prefill, not the
  materialize step.

This is intended for the live Studio provider: Qwen3.6, buyers, `canary`,
8 seats.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE (correctness, MLX state semantics, concurrency, tests)

Check:
- Checkpoint positions and chunk-split math, including off-by-one at C.
- Whether a restored recurrent state exactly corresponds to C tokens, and
  whether the attention trim leaves offset == C (`begin` trims by
  `canonical.count - C`).
- Checkpoint freshness: re-snapshot vs reuse on a hit that is already past a
  checkpoint.
- MambaCache `state` aliasing: can a later in-place update ever mutate a stored
  snapshot?
- Materialize correctness and token-count consistency, including the dropped
  trailing stop and tokens decoded past the stop within a lockstep window.
- Cancellation and failure leaks.
- Scheduler actor reentrancy around the snapshot and materialize awaits.
- Tests that would fail on a real regression.

Round 1 code-lane MEDIUM (cancel lost across the snapshot await) is fixed in HEAD, with `testCancelDuringRecurrentSnapshotCancelsWithoutMaterializing`. The test fails without the fix (verified) and passes with it. Re-check the fix and the whole change.
