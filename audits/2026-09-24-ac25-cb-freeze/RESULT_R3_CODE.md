## Raw output

```text
I'll start from the freeze-audit method, the prior 0/0/0 evidence at `6f75c3a1`, and the new hybrid-cache / isolation-probe commits, then review the full `origin/main...HEAD` diff for CODE-lane correctness.Prior freeze artifacts are already in the tree; next I’ll confirm HEAD vs `6f75c3a1` and read the R3 CODE prompt plus the hybrid-cache source.HEAD is `87ba9771`, one commit past the last freeze. I’ll list the hybrid-cache and probe diffs next, then read those paths in source.The new surface is concentrated in the hybrid pack/sync, isolation probe, and status snapshot. I’ll read those functions and the tests that claim to pin them.I have the diffs. Next I’ll read Mamba offset/state, decode/finish, the probe gate, and the tests that should catch a real regression.The home-wide search is too broad. I’ll pin MambaCache in the Swift package checkouts and keep reading the probe-loop tests and snapshot path.The Mamba offset copy is unused on Qwen3.6’s linear path; next I’ll pin retained-handoff gating and run the existing hybrid, probe, and status tests.Code review of `campaign/ac25-m2-api-lifecycle` `87ba9771` against `origin/main`, focused on the post-`6f75c3a1` hybrid-cache merge (`46df88d9` / `e38840a5` / `422a83a7`) and the isolation-probe pair loop (`87ba9771`). Phase A / R2 surfaces were re-read only where this delta sits on them: `packFromRows` / `syncRowsFromBatch`, `finish` / `cancelInFlight`, retained-cache admission, and `measurePagedKVRuntime`. No CRITICAL, HIGH, or MEDIUM defects.

## Mamba row state (join / leave / ragged)

Prefill is still per-row (`PagedKVRuntimeBridge.swift:527`). Batched decode packs layer-wise: attention layers stay on `PagedKVBatchLayerCache`; linear layers concatenate row-local `MambaCache` slots on axis 0 (`packMambaRows`, `:1018`). An empty joining row gets zeros with the populated peer’s slot shape (`:1026–1031`), which is the same init Qwen3.6 uses when `cache?[0]` is missing (`mlx-swift-lm` `Qwen35.swift:242–246`). Shape/dtype/batch-dim guards throw `continuous_batching_invalid_cache_layout`. After each uncompiled step, `validateBatchState` requires two slots with `dim(0) == rows.count` (`:993–998`, called at `:865`).

Leave/rejoin keeps the surviving row’s objects. `finish` (`:621`) calls `invalidateDecodeSession`, which syncs then drops the session (`:920–930`); `removeRowState` then drops only the finished id. The next window sees changed `requestIDs`, syncs again, and `makeBatchedCaches` packs the remaining row caches (`:786–790`). The mixed-cache test’s expected snapshots (`[204, 211]` rejoin, `[204]` after leave, `[205, 0]` one-token join) encode that contract; they skipped here because the host has no MLX metallib. Studio isolation with pair 2, including leave/rejoin, matches it.

`syncMambaRows` (`:1046`) copies each row’s conv/SSM slice and sets `rows[rowIndex].offset = batch.offset`. Qwen3.6 linear attention never increments `offset`; it writes `cache[0]` / `cache[1]` and calls `ArraysCache.advance(S)` on `lengths` / `leftPadding` (`Qwen35.swift:288–291`, `KVCache.swift:1297–1304`). Those metadata fields are filled by `withPreparedCache` for the current `[B,1]` chunk and cleared in `finalize`. Equalizing unused `offset` after a lockstep step does not rewrite conv/SSM tensors. Ragged sequence length stays an attention-layer problem; `packFromRows` still sets `batchedOffset` only when every row offset is equal (`:1352–1353`), and `syncRowsFromBatch` still returns immediately when it is nil (`:1157`). Hybrid attention layers keep that ragged path.

Cancellation looks up paged handles with `pagedAttentionCaches` (`:666`, `:761`). Hybrid serve installs `contiguousCacheBridge = nil` (`ModelRuntime.swift:3163`), so discard is a no-op and retained handoff is absent. A cache-hit request is kept off the scheduler by `canaryShouldSerialRouteCachedHitMissingRetainedHandoff` whenever `cachedPromptTokens > 0` (`:3809–3818`). A retained sequence that still reached admission would throw `continuous_batching_paged_kv_handoff_unavailable` because the bridge is nil (`ContinuousBatchScheduler.swift:2249`), and `installRetainedPagedKVCache` throws `continuous_batching_retained_hybrid_cache_unavailable` for mixed kinds (`PagedKVRuntimeBridge.swift:631`). `compiledDecode` is false on the serve backend for every layout (`ModelRuntime.swift:3183`); `canCompile` also requires all `.pagedAttention` (`:799`).

## Probe loop

`computePagedKVRuntimeProbes` (`ModelRuntime.swift:1698–1722`) writes `moeProbe = attempt` every iteration and breaks on the first `challengeDistinguishing` result. A non-distinguishing pair is replaced by the next attempt. `runMoEInputIsolationProbe` sets `proven` only when `challengeDistinguishing` holds (`PagedKVRuntimeParityProbe.swift:277–280`, `:346–350`). `challengeDistinguishing` (`:604–614`) requires a non-empty first row and distinct `top1` at every shared step.

`measurePagedKVRuntime` (`ModelRuntime.swift:1520–1525`) still requires the full shape: `proven`, `challengeDistinguishing`, `rowsDecodedInSharedForward == 2`, `rowFailures == 0`, `crossRowDivergences == 0`. `testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation` injects `proven: true` with `challengeDistinguishing: false` and the measurement stays nil.

Hybrid `challengeDistinguishing` is the AND of the two-step first window and the leave/rejoin step (`PagedKVRuntimeParityProbe.swift:342–343`). The loop’s break flag is that combined value. A first-window leak whose second-window serial `top1`s happen to match would continue to the next pair. Attach still only opens on a later pair that is distinguishing on both windows with zero divergences. A shared-forward mixup that is visible on one distinguishing pair is visible on the pair that opens attach.

## Status snapshot

`ModelRuntime` is an actor. `currentSnapshot` (`:2378`) reads mode, attach decision, cache class, and capability on that actor, then `await continuousBatchScheduler?.metrics()`. `metrics()` (`ContinuousBatchScheduler.swift:1372`) copies integers under the scheduler actor and does not call back into `ModelRuntime`. `/v1/status` now always takes that snapshot (`HTTPServer.swift:553`) so the `continuous_batching` block is present with warm-swap off. `ProviderStatusTests` pin the JSON shape, including the inactive defaults when the runtime snapshot is missing.

## Tests run

`swift test --filter` of the hybrid / attach-gate / status / FR-CB6 cases: 22 executed, 4 skipped (2 MixedCache metallib, 2 real-model isolation env gates), 0 failed. Restored `phase3-binary/Package.resolved` after the run.

Tests, and whether they fail on a real regression:

- `testMoEDispatchGateRequiresGenuinelyProvenSharedForwardIsolation` fails if attach trusts `proven` alone or accepts `challengeDistinguishing: false`.
- `testQwen36HybridArchitectureRequiresExactTupleAndConfigMetadata` / `testMixedCacheClassRequiresVerifiedHybridArchitecture` fail if `mixed` attaches without the exact id + `Qwen3_5ForConditionalGeneration` bit.
- `testQwen36MixedRuntimeAttachesOnlyWithVerifiedArchitecture` fails if status `active`/`cacheClass` drift from that gate.
- `PagedKVBatchedToleranceTests` fail if the leak guard or runner-up tolerance predicate changes.
- `PagedKVRuntimeMixedCacheTests` would fail on pack/sync/leave/join bugs when metallib is present. They skipped on this host.
- `87ba9771` has no test. `PagedKVRuntimeProber` is injectable; a loop that kept going after a distinguishing failure, or that returned a non-distinguishing last pair as the attach evidence, would still pass the injected-result gate tests.

### LOW

1. `ModelRuntime.swift:1698` — The isolation-pair loop has no regression test. A change that continued after `challengeDistinguishing == true` with `crossRowDivergences > 0`, or that handed a non-distinguishing last pair to `measurePagedKVRuntime` without the existing full-shape guard, would not fail any current test. Fix: inject a `PagedKVRuntimeProber` that returns a non-distinguishing pair, then a distinguishing failure, then a distinguishing pass, and assert which result is measured.

2. `PagedKVRuntimeMixedCacheTests.swift:12` and `:57` — Leave/join/zero-init Mamba packing is only executed when MLX metallib is present. On this host both cases skip. Studio FR-CB15 / isolation evidence is the live proof. Same class as the R1 ragged-row carry.

3. `ContinuousBatchScheduler.swift:2304` — Successful admission writes `event=batching_admitted` with `FileHandle.standardError.write`. Closed stderr can still abort the process the way the R1 CBTrace write did before `db762e12`. Fix: `try? standardError.write(contentsOf:)`.

VERDICT: PASS

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
