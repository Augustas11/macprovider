# Codex audit: Qwen3.6 CB performance milestone (#1646, #1742)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-cb-sampling`. Branch:
`campaign/1646-cb-sampling`. Review the full diff `git diff b0f3d45f..HEAD --
phase3-binary specs` (the commits `3a91f1bc`, `2d34c88b` and `bd8c8ded`),
not each commit alone.

## The change
- **In-place paged KV (`3a91f1bc`, `PagedKVCache.swift` and
  `PagedKVBatchLayerCache` in `PagedKVRuntimeBridge.swift`).**
  - `PagedKVCache.update` used to re-concatenate the row's whole K/V history
    and re-split it into blocks on every decode step, which is O(context) per
    token.
  - It now keeps contiguous `[B,H,capacity,D]` buffers that grow in
    256-token steps, capped at `maxResidentTokens`, and writes new tokens by
    slice assignment.
  - Block views are derived on demand, and `trim` is O(1).
  - The batch layer cache writes ragged rows in place while every row's
    `mutationCount` still matches, and rebuilds otherwise.
  - Tests: `PagedKVCacheStorageTests`; byte-identical output on a random-weight
    model locally.
- **LaunchAgent priority (`2d34c88b`, SPEC-003 v0.11.4).**
  - The provider plist changes from `ProcessType` `Adaptive` to `Standard` in
    `install.sh`, `launchd-plist-template.plist` and the signed
    compatibility-set template that auto-update renders.
  - `Adaptive` left the daemon at Mach priority 4, and decode dropped from
    37.8 to 22.3 tok/s on the M3 Ultra.
  - The watchdog and reload helper jobs stay `Background`.
  - Test: `install_prefix.test.sh`.
- **Bounded decode window while prefilling, and no prefill logits
  (`bd8c8ded`, SPEC-038 v0.2.10 FR-CB2).**
  - `lockstepDecodeWindowSteps` returns up to `maxDecodeStepsWhilePrefilling`
    (production 8) while a prompt is mid-prefill and no request is waiting or
    admitting. A waiting or admitting request still forces 1.
  - Bridge prefill evaluates `state.caches` instead of `output.logits`.

## Evidence
`docs/runbooks/continuous-batching-qwen36-throughput-decomposition-2026-09-25.md`
covers the steady-state decode before and after, the MLX ceiling, the priority
A/B, parity (`isolate_q36` / `crossrow_q36`) and 0 forward failures.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
