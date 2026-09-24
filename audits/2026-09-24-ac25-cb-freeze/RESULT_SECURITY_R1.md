## Raw output

```text
I'll review the security and money-path surface of the commits after `689848aa`: billing and receipts, KV isolation, the lab readiness waiver, and `error_queue_full` re-route. Reading the merge-base diff and the specs those commits touch.The branch is `campaign/ac25-m2-api-lifecycle`. Next I’ll read the post-`689848aa` code diffs that touch billing, receipts, KV isolation, and the lab waiver.The diffs show four money-path surfaces. I’ll read the EOS trim, queue-pressure mapping, lab waiver, and lazy KV record in the surrounding code.Security and money-path review of the commits after `689848aa` found no CRITICAL, HIGH, or MEDIUM issues. No LOW or INFO either.

The two queue-pressure codes reach the coordinator as `error_queue_full` only before this attempt has offered a token. `InferenceRelay.errorEndFrame` maps `continuous_batching_stream_backpressure` and `continuous_batching_queue_wait_timeout` to that status. Every throw of those errors is in `submit` or `enqueue`, and `offer` returns false before the event is queued, so that waiter's sink is never called. Post-token delivery backpressure stays `error_internal`. On the streaming coordinator path, `error_queue_full` is re-routed only while the attempt is still uncommitted. The error frame carries no receipt. Direct HTTP treats any code other than `model_not_loaded` as not receipt-eligible. SPEC-005 credits `error_queue_full` at zero. A coordinator buyer request gets a fresh relay id; an idempotency-key resend is answered 409 and is not dispatched, so this status does not start a second settlement of an in-flight row.

Trailing model end-of-sequence tokens are dropped from usage and from the cache token sequence only when the row's terminal status is stop and the last generated id is in the model stop set. The billed count is `completionTokens` minus that one id. Harmony `<|return|>` and `<|call|>` stay in the generated-token list and in `generatedCompletionTokens`, which is what the receipt's `tokensOut` uses. Buyer-visible `completion_tokens` for a non-Harmony row is that same trimmed count. Studio case 9 already matched serial usage on both stop and length rows.

The lazy record keeps the live per-row caches and copies bytes only in `materializeContiguousByteCache`. That copy runs `physicalLayerBlocks`, which requires `offset == table.logicalTokenCount` and a matching shape on every block, and then copies. `release` drops the record. Ragged rows leave `batchedOffset` nil, so `syncRowsFromBatch` does not write the padded batch tensors back; padding is zeros, and the mask uses each row's own length.

`waivesLabLoopbackCatalogReadiness` is true only when `--isolate-lifecycle` is set, the credential store is the protected file, `URL.host` is `localhost`, `127.0.0.1`, or `::1`, and startup has no catalog envelope. The flag is CLI-only. The waiver and the socket both use `resolved.coordinatorURL`. A production host, a dotted suffix, `0.0.0.0`, a decimal address, and an IPv4-mapped address all fail the host check. A userinfo URL whose host component is loopback is rejected in `CoordinatorClient` before a session exists. Reaching the waiver promotes that loopback join to `servingBuyers` without a catalog envelope, which is what lets the lab coordinator hold the session.

`CBTrace` is off unless `MACPROVIDER_CB_TRACE=1`. The lines are request ids, stage names, counts, the terminal-status enum, and the error's type name. `finishDrain` re-checks the queue under the same lock that clears `draining`, and the delivery completion runs once. The disconnect test double only adds `isSettlementReceiptEligible` so the stub matches the post-#1707 protocol.

`swift test --filter 'InferenceRelayQueuePressureTests|ContinuousBatchStopTokenTests|testLabLoopbackReadinessWaiverRequiresEveryIsolatedLabCondition|testNoJoinProtectedFileIsolatesLabServe'` passed, 5 tests, 0 failures.

VERDICT: PASS


Memory flush started.
Memory flush completed.
Memory flush started.
Memory flush completed.
Memory flush started.

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
