# Codex freeze audit — PR #1716 (Build 5 continuous batching, #1646), full diff

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-ac25-m2`. Branch:
`campaign/ac25-m2-api-lifecycle`. Review the COMPLETE diff as it would land:
`git diff origin/main...HEAD -- ':!docs' ':!audits'` (32 files, ~3.7k lines).
Earlier review rounds on this branch used a different model; treat them as
untrusted and review everything independently. What the diff contains:

1. SPEC-038 AC-25 Phase A API lifecycle. A shared
   `ContinuousBatchSchedulerError.asAPIError()`, distinct queue / delivery /
   idempotency error codes, a bounded admission wait
   (`continuous_batch_queue_wait_timeout_ms`), and direct-HTTP disconnect
   cancelling the row.
2. Batched-output fixes:
   - `compiledDecode: false` on the serve path. The `MLX.compile` replay froze
     the KV offset.
   - The model's EOS token ids join the batched stop sequences, and the
     trailing EOS is dropped from usage. Harmony return/call tokens are kept.
   - The drain race (D-4) fix, `finishDrain` re-check under lock.
   - Ragged rows: `packFromRows` / `syncRowsFromBatch`.
   - A lazy KV record (no per-window host copy; `validateRecordable`).
3. Relay: CB queue-full / queue-wait timeout → `error_queue_full` (SPEC-001
   FR-27 v1.9.20, SPEC-038 v0.2.4).
4. A narrow lab-only waiver of catalog readiness for `--isolate-lifecycle`
   against a loopback coordinator (`waivesLabLoopbackCatalogReadiness`).
5. #1731 merge: Qwen3.6-27B hybrid cache. `PagedKVCache` covers the 16
   full-attention layers and row-local `MambaCache` covers the 48
   linear-attention layers (`PagedKVSharedLayerBatch`, `packMambaRows`,
   `syncMambaRows`). First turn only. Adds the hybrid parity/isolation probe
   and a `/v1/status` CB snapshot. The isolation probe walks ordered prompt
   pairs until one is `challengeDistinguishing`
   (`firstDistinguishingIsolationProbe`).
6. `CBTrace` lab trace (`MACPROVIDER_CB_TRACE=1`) and safe telemetry writes.
7. An MLX buffer-cache limit: `mlx_cache_limit_mb` /
   `MACPROVIDER_MLX_CACHE_LIMIT_MB`, applied before the MLX model loads.

Intended use: enable `continuous_batching: canary` for one exact tuple (Mac
Studio M3 Ultra 256 GB, `qwen/qwen3.6-27b`, cache_class `mixed`, fp16, 8 seats,
`mlx_cache_limit_mb: 2048`) on a signed candidate serving real buyers. The lab
evidence is in `docs/runbooks/continuous-batching-qwen36-evidence-2026-09-24.md`.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report each finding with file:line, a
concrete failure scenario, and a fix. Do not manufacture findings. Run the
existing tests if useful (`cd phase3-binary && swift test --filter ...`;
MLX-kernel tests skip locally). End with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
## Lane: ARCHITECTURE (spec conformance, contracts, rollout safety)

Check:
- SPEC-038, SPEC-039, and SPEC-001 text versus the code, including
  `specs/CONFORMANCE.json` and `AUTHORITY.json` consistency.
- FR-CB10 tuple fail-closed behavior.
- Canary vs on vs off semantics.
- First-turn-only hybrid scope enforcement.
- Coupling of the new knobs.
- Whether the one-tuple canary enable is safe to ship on a signed candidate:
  rollback path and what an operator must set.
