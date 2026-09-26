## Raw output

```text
I'll review the architecture of the post-`689848aa` commits against the specs and the surfaces that consume those contracts, reading the merge-base diff and the existing tests only.The branch is the campaign worktree. Next I’ll read the post-Phase-A code and the SPEC contracts those commits claim to satisfy.The relay mapping is a contract change across three services. I’ll trace `error_queue_full` through the coordinator and gateway, then read the decode, waiver, and paged-KV changes.The relay contract matches the existing `error_queue_full` re-route path. Next I’ll check the serve-path decode boundary, the lab waiver, and the paged-KV record change.The spec headers moved to 1.9.20 and v0.2.4, but the conformance ledger still names the old versions. I’ll confirm that with the existing governance check, then run the contract tests.Architecture review of `campaign/ac25-m2-api-lifecycle` against `origin/main`, focused on the commits after `689848aa`. The buyer-visible relay, decode, lab, and paged-KV contracts agree with the specs. The spec-version ledger does not.

## MEDIUM

`specs/CONFORMANCE.json:12` still says SPEC-001 `1.9.19`, and `specs/CONFORMANCE.json:1094` still says SPEC-038 `v0.2.3`. The normative headers are `1.9.20` and `v0.2.4`. `scripts/check_spec_governance.py` reports both (`SPEC-001.version` and `SPEC-038.version` do not match the header) and returns 1 when that list is non-empty. `scripts/tests/test_byom_contract_lock.py:324` still requires `**Version:** 1.9.19`; that test failed. `specs/README.md` is already current (`gen_spec_index.py --check` passed).

A governance run on this tree is red, and any reader of `CONFORMANCE.json` still has the pre-FR-27 versions as current. Set those two `version` fields to `1.9.20` and `v0.2.4`, and move the `1.9.19` pins at `test_byom_contract_lock.py:324`, `:328`, and `:338` to `1.9.20`.

## LOW

`ContinuousBatching.swift:469` writes the trace with `FileHandle.standardError.write(Data)`. `PagedKVRuntimeDiagnostics.swift:21` documents that this deprecated write raises an uncatchable exception on a closed stderr and terminates the process; that helper uses `try? write(contentsOf:)`. With `MACPROVIDER_CB_TRACE=1` and a broken stderr pipe, the next traced stage (submit, admit, or drain) aborts serving. Use the same `write(contentsOf:)` call. The gate itself is a reasonable permanent diagnostic: it is off unless the variable is exactly `1`, the event string is not built while off, and the line is request id and stage only.

## INFO

SPEC-038's queue-wait row says the relay status is `error_queue_full` and the provider log keeps `continuous_batching_queue_wait_timeout`. `InferenceRelay.swift:1190` maps both pre-admission codes to `error_queue_full` with the same message, `Inference engine unavailable`. The scheduler records `queue_wait_timed_out` versus `backpressure_rejected` only in the in-memory diagnostic ring (`ContinuousBatchScheduler.swift:2773`), which the serve path does not print. Coordinator `request_log.error_code` is `error_queue_full` for both, which is the relay row's wire status. Buyer routing is unchanged. If an operator line is required, log the request id and the original code at the map site.

## Contracts that hold

**FR-27 / SPEC-038 v0.2.4.** The plaintext relay sends `continuous_batching_stream_backpressure` and `continuous_batching_queue_wait_timeout` as `error_queue_full` with no provider `retryable` override. Post-token `continuous_batching_stream_delivery_backpressure` stays `error_internal`. The coordinator already treats `error_queue_full` as `wsForwardQueueFull`: `wsEndHTTPStatus` is 503, the provider is marked busy, and `skipRetryBudgetCheck` advances to the next candidate without spending the buyer retry budget. When no candidate remains, `writeError` / `writeStreamForwardError` emit 503 `no_provider_available` (`retryable: true`, `inference_ran: false`). The gateway classifies that code in `gatewayRetryableByCode` and `setGatewayRetryAfter` restores `Retry-After: 1` from `gatewayRetryAfterByCode`. No coordinator or gateway edit is required, and no consumer on this tree still needs those two scheduler codes to arrive as `error_internal`. Direct HTTP still emits the original codes, marked retryable, with the provider's own `Retry-After`. Relay-blind failures stay `relay_blind_committed_failed`, which is the right boundary for a leg that cannot be handed to another provider.

**`compiledDecode: false`.** The frozen KV-offset bug is in `PagedKVSharedForwardBackend`'s compiled lockstep graph. The backend already defaults the flag to false, and `ModelRuntime`'s serve constructor hard-codes false. `MSBThroughputCommand` is a harness and still defaults compile on; it is not a buyer-serving caller. No SPEC requires compiled decode on the serve path.

**Lab waiver.** `waivesLabLoopbackCatalogReadiness` sits next to the existing lab admission relaxation and waives only the readiness gate that relaxation makes unreachable. All four conditions are required: `--isolate-lifecycle`, protected-file custody, a literal loopback host (`localhost`, `127.0.0.1`, or `::1`), and no catalog trust. `CoordinatorClient` defaults the flag to false; only `ServeCommand` sets it. A missing envelope returns confirmed and prints `WARN lab_loopback_readiness_waived`. A real catalog envelope still polls. A production coordinator URL and the keychain store keep the gate.

**FR-PKV10.** `materializeContiguousByteCache` now reads the recorded live caches at materialize time. `physicalLayerBlocks` fails closed when `offset` no longer matches the table. `reattachPagedKVCache` already returned those same caches, and `retain()` requires no in-flight decode step, so extraction runs on a quiescent row. `validateRecordable` is the structural check used on the per-window record; the full per-block shape check still runs at materialize and at trim. `packFromRows` sets `batchedOffset` only when every row shares one length, and `syncRowsFromBatch` returns when that value is nil, so a ragged row is not overwritten with the padded batch length.

**Phase A.** The disconnect test double now reports `isSettlementReceiptEligible` and `settlementDisposition: .eligibleOwner`, matching post-#1707 eligibility. Product eligibility is unchanged. Delivery backpressure stays outside the new map.

`swift test --filter 'InferenceRelayQueuePressureTests|ContinuousBatchStopTokenTests|testLabLoopbackReadinessWaiverRequiresEveryIsolatedLabCondition|testOfferRacingDrainExitIsDeliveredAndTerminalCompletes'` passed, 5 tests.

VERDICT: FAIL (0/0/1)


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
