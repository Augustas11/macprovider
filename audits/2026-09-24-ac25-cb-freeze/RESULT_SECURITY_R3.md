# Freeze audit round 3 — SECURITY / MONEY-PATH

HEAD `87ba9771`. Scope: full `origin/main...HEAD` with focus on new work since
`6f75c3a1` (`46df88d9`, `e38840a5`, merge `422a83a7`, `87ba9771`).

## Verdict

0 CRITICAL, 0 HIGH, 0 MEDIUM. No LOW or INFO carried.

**VERDICT: PASS**

## Hunt results

### Cross-request Mamba state

Joining rows with empty recurrent slots are packed as zeros of the populated
peer's per-row shape (`PagedKVRuntimeBridge.swift:1026-1032`), then concatenated
on axis 0. After the shared forward, `syncMambaRows` writes
`batch[rowIndex ..< rowIndex+1, .ellipsis]` back onto that row
(`:1051-1056`). Qwen3.6 linear attention reads `MambaCache[0]` (conv window)
and `MambaCache[1]` (delta state), not `BaseKVCache.offset`
(`mlx-swift-lm` `Qwen35.swift:241-290`). Copying `row.offset = batch.offset`
(`:1055`) does not mix conv/delta tensors.

Membership change syncs the old batch, then packs the new row set
(`:786-796`). `finish` invalidates the session containing that id and drops
the row (`:621-623`, `:920-930`). Prefill is per-row (`:527-540`). Multi-row
decode fail-closes if any row carries `LMOutput.State` (`:778-780`, `:872-874`).
Compiled decode is off on the serve path and additionally requires every layer
to be `.pagedAttention` (`ModelRuntime.swift:3183`,
`PagedKVRuntimeBridge.swift:799-802`).

### Hybrid attach gate

`mixed` attaches only when all of these hold:

- serving id lowercased equals `qwen/qwen3.6-27b` and `config.json`
  `architectures` contains `Qwen3_5ForConditionalGeneration`
  (`ModelRuntime.swift:1846-1852`)
- runtime `newCache()` is heterogeneous (`:1776-1778`) and topology is
  `MambaCache` plus `KVCacheSimple` only (`:1782-1797`, `:1671-1674`)
- live parity plus batched isolation, including
  `challengeDistinguishing` (`:1511-1526`)
- sizing proof covers exact model id, SHA-256, tokenizer, chat template
  (`PagedKVEngine.swift:191-203`)

`supportsCacheClass("mixed")` without `hybridDecoderArchitectureVerified` is
false (`PagedKVEngine.swift:352-357`). A neighboring id such as
`qwen/qwen3.8-27b` does not verify. Isolation probe pairs: a
non-distinguishing pair cannot set `proven`; the first distinguishing pair's
verdict is final (`ModelRuntime.swift:1716-1718`,
`PagedKVRuntimeParityProbe.swift:276-280` and `:346-350`). Other-row token is
rejected even inside the numerical-tolerance band
(`PagedKVRuntimeParityProbe.swift:96-97`).

### `/v1/status` and `batching_admitted`

`RuntimeContinuousBatchingSnapshot` publishes mode, active, unsupported
reason, paged-KV decision, cache class, and occupancy counters
(`HTTPServer.swift:2017-2034`). No request ids, prompts, tokens, or
conversation keys. The listener binds `127.0.0.1` (`:200`).
`event=batching_admitted action=scheduler_admitted` is a fixed stderr line
with no request id (`ContinuousBatchScheduler.swift:2304`).

### Usage / retained credit

Hybrid serve path sets `contiguousCacheBridge = nil`
(`ModelRuntime.swift:3161-3164`). `retainTerminalCache` returns nil without
that bridge (`ContinuousBatchScheduler.swift:2816`), so a successful first
turn releases the handle and does not commit a retained sequence. The
conversation lease is aborted (`ModelRuntime.swift:4017-4018`). Positive
cached-token hits are fenced before submit on both complete and stream
(`:3814-3818`, `:3890-3891`, `:4115-4116`). A retained hybrid install still
throws `continuous_batching_retained_hybrid_cache_unavailable`
(`PagedKVRuntimeBridge.swift:631-632`). Successful first-turn settlement stays
`eligibleOwner` with `cachedPromptTokens` from the request (zero on this
path).

### Hybrid cancellation

`pagedAttentionCaches` is `compactMap` to `PagedKVCache`
(`PagedKVRuntimeBridge.swift:1014-1015`). Hybrid record/discard is a no-op
because the serve-path bridge is nil. `cancelInFlight` drops the session and
all rows (`:661-667`).

## Tests run

```
swift test --filter 'testQwen36HybridArchitectureRequiresExactTupleAndConfigMetadata|testQwen36MixedRuntimeAttachesOnlyWithVerifiedArchitecture|testMixedCacheClassRequiresVerifiedHybridArchitecture|testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation|testStatusResponsePublishesInactiveContinuousBatchingBlockWithoutRuntimeSnapshot|testStatusResponsePublishesContinuousBatchingRuntimeSnapshot|testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin|testMixedMambaAndPagedAttentionCachesShareForwardAndRetainRowState|testConversationKeyWithoutRetainedHandoffRunsAsFreshSchedulerRow'
```

7 passed, 2 skipped (`PagedKVRuntimeMixedCacheTests`: MLX default metallib
unavailable on this host; Studio leave/join isolation is the live proof).

```
swift test --filter 'PagedKVBatchedToleranceTests|testCanarySerialRoutesCachedHitWithoutRetainedPagedHandoff'
```

9 passed, 0 failures.

`phase3-binary/Package.resolved` was restored after `swift test`.
