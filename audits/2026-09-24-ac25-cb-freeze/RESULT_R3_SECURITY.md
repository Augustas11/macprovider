## Raw output

```text
I'll start the security/money-path freeze audit by reading the review method, prior freeze notes, and the hybrid-cache diff since `6f75c3a1`.Prior freeze notes and the R3 security prompt are in the tree; I'll read those, then inspect the hybrid-cache diff against origin/main.The post-`6f75c3a1` slice is four commits. Next I’ll read the hybrid pack/sync, attach-gate, status, and billing paths in parallel.I'll read the hybrid cache, attach gate, status snapshot, and billing surfaces in the Swift sources next.I'll read the attach gate, Mamba pack/sync, isolation probe, and status/billing paths next.I’ll look up `MambaCache` offset semantics, `/v1/status` auth, hybrid usage/receipt, and the mixed-cache tests.Isolation and attach gates look closed. Next I’ll run the existing hybrid, status, and isolation tests.Security / money-path freeze of `87ba9771` (full `origin/main...HEAD`, focus since `6f75c3a1`) found no CRITICAL, HIGH, or MEDIUM issues. No LOW or INFO carried.

Written to `audits/2026-09-24-ac25-cb-freeze/RESULT_SECURITY_R3.md`.

### Mamba isolation
Joining rows with empty recurrent slots are packed as zeros of the populated peer’s per-row shape (`PagedKVRuntimeBridge.swift:1026–1032`), then concatenated on axis 0. After the shared forward, `syncMambaRows` writes `batch[rowIndex..<rowIndex+1, .ellipsis]` back onto that row (`:1051–1056`). Qwen3.6 linear attention uses `MambaCache[0]` (conv window) and `MambaCache[1]` (delta state). Copying `row.offset = batch.offset` (`:1055`) does not mix those tensors.

Membership change syncs the old batch, then packs the new row set (`:786–796`). `finish` invalidates the session containing that id and drops the row. Prefill is per-row. Multi-row decode fail-closes if any row carries `LMOutput.State`. Compiled decode is off on the serve path and also requires every layer to be `.pagedAttention`.

### Attach gate
`mixed` attaches only when all of these hold: serving id `qwen/qwen3.6-27b`, `config.json` architectures contain `Qwen3_5ForConditionalGeneration` (`ModelRuntime.swift:1846–1852`), runtime topology is `MambaCache` plus `KVCacheSimple` only, live parity plus batched isolation including `challengeDistinguishing`, and the sizing proof covers exact model id + SHA-256 + tokenizer + chat template. `supportsCacheClass("mixed")` without that architecture flag is false. A neighboring id such as `qwen/qwen3.8-27b` does not verify.

A non-distinguishing isolation pair cannot set `proven`; the first distinguishing pair’s verdict is final. An other-row token is rejected even inside the numerical-tolerance band.

### `/v1/status` and `batching_admitted`
The snapshot publishes mode, active, unsupported reason, paged-KV decision, cache class, and occupancy counters (`HTTPServer.swift:2017–2034`). No request ids, prompts, tokens, or conversation keys. The listener binds `127.0.0.1`. `event=batching_admitted action=scheduler_admitted` is a fixed stderr line with no request id.

### Usage / retained credit
Hybrid serve path sets `contiguousCacheBridge = nil` (`ModelRuntime.swift:3161–3164`). `retainTerminalCache` returns nil without that bridge, so a successful first turn releases the handle and aborts the conversation lease. Positive cached-token hits are fenced before submit on both complete and stream (`:3814–3818`). A retained hybrid install still throws `continuous_batching_retained_hybrid_cache_unavailable`. Successful first-turn settlement stays `eligibleOwner` with `cachedPromptTokens` from the request (zero on this path).

Hybrid cancellation looks up paged handles via `pagedAttentionCaches` (`:1014–1015`); record/discard is a no-op because the serve-path bridge is nil. `cancelInFlight` drops the session and all rows.

### Tests
`swift test --filter 'testQwen36HybridArchitectureRequiresExactTupleAndConfigMetadata|testQwen36MixedRuntimeAttachesOnlyWithVerifiedArchitecture|testMixedCacheClassRequiresVerifiedHybridArchitecture|testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation|testStatusResponsePublishesInactiveContinuousBatchingBlockWithoutRuntimeSnapshot|testStatusResponsePublishesContinuousBatchingRuntimeSnapshot|testMixedCacheIsolationProbeCoversLockstepWindowBeforePeerRejoin|testMixedMambaAndPagedAttentionCachesShareForwardAndRetainRowState|testConversationKeyWithoutRetainedHandoffRunsAsFreshSchedulerRow'`: 7 passed, 2 skipped (`PagedKVRuntimeMixedCacheTests`, MLX default metallib unavailable on this host).

`swift test --filter 'PagedKVBatchedToleranceTests|testCanarySerialRoutesCachedHitWithoutRetainedPagedHandoff'`: 9 passed, 0 failures.

`phase3-binary/Package.resolved` restored after `swift test`.

**VERDICT: PASS**

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
