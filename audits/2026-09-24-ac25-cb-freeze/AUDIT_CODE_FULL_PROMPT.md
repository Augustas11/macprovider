# Freeze audit — #1716 (Build 5 CB: AC-25 lifecycle, batched-output fixes, M3 serving path)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads or
exploit inputs; describe any gap abstractly (field + condition) in prose.

Worktree `/Users/augstar/macprovider-ac25-m2`, branch
`campaign/ac25-m2-api-lifecycle`. Review the FULL combined diff as it will
land: `git diff origin/main...HEAD` (merge-base diff). Phase A (commits up to
`689848aa`) passed a three-lane audit at 0/0/0; review it again only where the
later commits interact with it. Focus on the commits after `689848aa`:

- `86cb70b5` test double conforms to #1707 receipt eligibility.
- `110bdcd0` serve path: `compiledDecode: false`; model EOS ids join the
  batched stop sequences; a trailing model EOS is dropped from usage and cache
  accounting (Harmony `<|return|>`/`<|call|>` stop the row but are kept).
- `890eb14e` `ContinuousBatchTokenDelivery`: `finishDrain` re-checks the queue
  under the lock that clears `draining` (fixes a lost terminal wakeup); adds
  `CBTrace` (env `MACPROVIDER_CB_TRACE=1`) request-lifecycle logging.
- `83b16e27` `InferenceRelay.errorEndFrame`: CB queue pressure
  (`continuous_batching_stream_backpressure`,
  `continuous_batching_queue_wait_timeout`) → `error_queue_full`; SPEC-001
  v1.9.20 FR-27 and SPEC-038 v0.2.4.
- `18f55877` `waivesLabLoopbackCatalogReadiness`: isolated lab join
  (`--isolate-lifecycle` + protected-file + literal loopback coordinator URL +
  no catalog trust) treats buyer-serving readiness as confirmed.
- `309b8a85` `PagedKVBatchLayerCache`: `packFromRows` sets `batchedOffset`
  only when all rows have equal offsets; `syncRowsFromBatch` returns early when
  `batchedOffset` is nil.
- `94285581` `PagedKVRuntimeContiguousCacheBridge.record` validates without
  the per-window host KV copy (`PagedKVCache.validateRecordable`);
  `materializeContiguousByteCache` builds physical blocks on demand from the
  recorded caches.

Studio evidence for all of this is in
`docs/runbooks/continuous-batching-ac25-lifecycle-evidence-2026-09-24.md` and
`docs/runbooks/continuous-batching-frpkv13-m3-evidence-2026-09-24.md`.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Findings as CRITICAL/HIGH/MEDIUM/LOW/INFO
with file:line, a concrete failure scenario, and a fix. State explicitly if
you find none. Do not manufacture findings. Do not propose SPEC edits unless
the code contradicts a SPEC. End with one line: `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE REVIEW — correctness, concurrency, test adequacy.

Hunt specifically for:
- `droppingTrailingModelStop` / `completionTokenCount`: any path where usage
  (billing) now differs from what the serial path would bill for the same
  output, or where a buyer `stop` string that happens to equal a model EOS
  token is double-handled.
- The drain fix: any remaining interleaving of `offer`, `stop`,
  `finish(afterDraining:)`, `timeout()`, `finishDrain` that strands an event or
  a completion, or calls a completion twice; capacity acquire/release balance.
- `packFromRows` / `syncRowsFromBatch`: any state where rows are equal-length
  but the batch tensors are not (or the reverse), so the lockstep path writes
  wrong KV back; interaction with `decodeLockstepWindow` session reuse and
  `clearDecodeSession`/`invalidateDecodeSession`.
- Lazy record: can `materializeContiguousByteCache` now observe caches that
  moved after `record`, or blocks released/reused by another request; does
  anything on the serve path still depend on the removed eager snapshot.
- Whether the new tests actually fail on the pre-fix code.
