## Raw output

```text
I'll review the full merge-base diff for the AC-25 lifecycle freeze, with the post-`689848aa` commits as the focus, and check the drain, usage, KV lockstep, and lazy-record paths against the existing tests.The branch is `campaign/ac25-m2-api-lifecycle` with a clean committed tip. I'll read the post-`689848aa` serve, drain, KV, and relay changes in source, then run the existing tests that cover them.The post-Phase-A delta is concentrated in the scheduler drain, stop-token accounting, KV lockstep, and lazy record. I'll read those functions and the tests that claim to pin them.The drain, stop-token, and KV paths read as consistent with the serial EOS rule. I'll run the existing tests that pin those contracts.Code review of `campaign/ac25-m2-api-lifecycle` against `origin/main` (`06a3fff3..HEAD`). Phase A was re-read only where the later commits sit on it: terminal delivery, stop matching, and the decode session. No CRITICAL, HIGH, or MEDIUM defects.

Usage matches the serial path. mlx-swift-lm's generate loop drops an end-of-generation id before it is appended, and it keeps Harmony `<|return|>` / `<|call|>` because those ids are removed from the stop set and then counted. The batched row does the same thing. `continuousBatchStopTokenSequences` adds one single-id sequence per `generationStopTokenIDs` entry on the raw context (`ModelRuntime.swift:4808`). `droppingTrailingModelStop` (`ModelRuntime.swift:4819`) removes the last id only when `terminalStatus == .stop` and that id is in the Harmony-preserving stop set. `completionTokenCount` subtracts that one id from `result.completionTokens`, which is `generatedTokens.count` on a successful finish. A buyer `stop` string that encodes to the same id is the same sequence: the scheduler strips it once from the visible tokens, and the usage adjustment subtracts it once. It is not subtracted twice. A buyer stop that does not end in a model end-of-generation id is left in the billed count, which is what the serial token list does before the text filter.

The retained cache still contains that end-of-generation id (`retainedLogicalTokenCount` includes it, and `commitTerminalKV` feeds it). `fullTokens` does not. That is the same split as the serial cache: `TokenIterator.next()` writes the id into the KV cache before the loop refuses to append it. On the next turn, `allocator.reattach` trims to `cachedPromptTokens` and `trimRecordedContiguousCache` moves the live cache down to that length.

The drain fix closes the lost-wakeup window. `offer`, `finishDrain`, `timeout`, and `stop` all take the same lock. `finishDrain` (`ContinuousBatchScheduler.swift:802`) either keeps draining when the queue is non-empty and the task is not cancelled, or clears `draining` and takes the completion in that same hold. An `offer` that arrives after the clear sees `draining == false` and starts a new drain. `timeout` is the only path that clears `draining` without releasing capacity, and it also sets `accepting = false` and invokes the completion, so a later `finishDrain` only releases the one held slot. `stop` clears the queue before it cancels, so a cancelled drain does not report success while leaving a queued event behind. I did not find an interleaving that strands a completion or runs it twice.

`packFromRows` (`PagedKVRuntimeBridge.swift:1221`) sets `batchedOffset` only when every row offset is equal. `syncRowsFromBatch` (`:1018`) returns immediately when it is nil, so a ragged window does not copy the padded batch tensor back onto the shorter rows. Equal offsets take the lockstep concat, and that path keeps one sequence length. Session reuse compares request ids in order; a departing row goes through `finish` → `invalidateDecodeSession`, which syncs and drops the session before the next window builds a new batch. `compiledDecode: false` on the serve backend means that window does not use the compiled writeback. The writeback path still slices each row to its own target before `packFromRows`.

`record` (`PagedKVRuntimeBridge.swift:137`) keeps the live `PagedKVCache` objects after `validateRecordable`. `materializeContiguousByteCache` (`:213`) rejects a table that is not the recorded one, and `physicalLayerBlocks` rejects a cache whose offset no longer matches that table. Serve handoff uses `reattachPagedKVCache`, which runs that same check. Decode does not read the removed byte snapshot. Row caches are not recycled onto another request; `finish` drops the row and leaves the record holding those objects until discard. A later request gets new cache objects.

Tests, and whether they fail on the pre-fix behavior:

- `testOfferRacingDrainExitIsDeliveredAndTerminalCompletes` fails on the old `finishDrain`: the racing `offer` stays queued, `drainGeneration` is already nil, and `timeout()` does not complete, so the 2-second expectation fires.
- `InferenceRelayQueuePressureTests` fails on the old `errorEndFrame`: both pre-admission codes fell through to `error_internal`.
- `testTrailingModelStopIsDroppedOnlyWhenTheRowStoppedOnIt` locks the pure function. It does not notice if a call site stops calling it.
- `309b8a85` and `94285581` add no test. `testRealSharedForwardBackendGreedyMatchesLoneAndMixedOffsetBatch` decodes one mixed-offset step through a token-id map and does not check row offsets after sync, so it passes on the old `batchedOffset = min` bug.

`swift test --filter` of those cases: 5 passed, 5 skipped, 0 failed. The five paged-KV cases skipped with "MLX default metallib is unavailable in this test host," so this host did not execute the live-cache bridge.

### LOW

1. `InferenceRelay.swift:1190` — Both pre-admission codes become `error_queue_full`, and the frame's `error` string is the generic "Inference engine unavailable". SPEC-038 v0.2.4 says the provider log keeps the distinct code. Default stderr does not. `CBTrace` is off unless `MACPROVIDER_CB_TRACE=1`, and it logs the error type name rather than the case. The in-memory scheduler diagnostic still separates `backpressure_rejected` from `queue_wait_timed_out`. Fix: one stderr line with the original `error.code` before the status is collapsed.

2. `PagedKVRuntimeBridge.swift:1018` and `:1221` — The ragged-offset fix has no regression test that fails on the old behavior (shorter row's offset becomes the batch max, next window mismatches the block table). The mixed-offset bridge test does not assert that.

VERDICT: PASS


Memory flush started.
Memory flush completed.
Memory flush started.
Memory flush completed.
Memory flush started.
Memory flush completed.

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
