# #1690 rebase onto origin/main (#1716): reconciliation note

- Before: `9cfb5b67` (backup branch `backup/1690-pre-rebase-2`), on base `0383756d`.
- After: `8eecfafe` on `origin/main` `5793b844`. 45 commits, same messages and authors. Not pushed.
- Only conflicted commits were amended, plus the two cross-boundary fixes in section 2, which were squashed into the commits that caused them.

## 1. Textual conflicts

| Commit | File | Resolution | Why |
|---|---|---|---|
| M2 `efcb2c3f` | `HTTPServer.swift`, stream `shouldCancel` | Kept #1716's `shouldCancel: { disconnect.isDisconnected }` and `emittedBuyerToken.set()`, and kept M2's comment. | One disconnect signal: #1716's `ClientDisconnectState`. |
| M2 `efcb2c3f` | `HTTPServer.swift`, `ResponseWriter` | Kept #1716's `init(context:retryAfterSeconds:)` and dropped M2's `channel` / `isClientConnected` (`channel.isActive`). | `isClientConnected` was a second disconnect probe that competed with the first. Every call site now uses `disconnect.isDisconnected`. |
| M3 `dccd502c` | `beta/DECISION_CRITERIA.md` | Main's Entry 247 (#1721) stays. #1690's entry is renumbered **Entry 248** and goes after it. | Both sides took 247. Nothing else refers to "Entry 247". |
| M5-fix `e47dc403` | `HTTPServer.swift`, streaming `catch is CancellationError` | One catch with no condition (#1716's), details below. The post-generation guard uses `!disconnect.isDisconnected`. | Satisfies #1716's AC-25 tests and #1690's `testHTTPStreamingClientDisconnectIsBuyerCancelNotProviderFailure` (`errorsTotal == 0`, a single `write_failed`). |
| Final-audit R1 `88824c71` | `HTTPServer.swift`, non-streaming path | Kept #1716's CBTrace lines. Kept the `shouldCancel` on the disconnect flag. Added #1690's post-generation disconnect guard. For the catch, see below. | Satisfies #1716's test (exactly one `pre_token_cancel`, 499 on a live socket) and #1690's rule (buyer cancel, never a failure). |
| `45d0702c` PeerCloseMonitor | `HTTPServer.swift`, `RouterHandler` stored properties | Union of #1716's `inflightDisconnects` / `queueWaitRetryAfterSeconds` and #1690's `peerCloseMonitor`. See the disconnect section. | |

How the streaming cancel catch resolves:
- `finishRequest(failed: false)` in every case. #1716 had `true`.
- If the buyer has already disconnected, nothing is written and the handler calls `writer.close()`. The audit records `write_failed` if SSE had started and a receipt was due, or `pre_token_cancel` if SSE had not started.
- If the socket is still open, #1716's single terminal is sent: `buyer_cancelled` with `inference_ran`, then `[DONE]`, or a 499 before SSE. After SSE has started, a receipt that was due also records `write_failed`.

How the non-streaming cancel catch resolves:
- `failed: false`.
- Always exactly one `pre_token_cancel` audit row.
- If the buyer disconnected, `writer.close()`. Otherwise a 499 `buyer_cancelled` response.

## 2. Semantic (cross-boundary) fixes

- **`settlementRuntimeSource` is a protocol requirement with no default** (#1690 M5). #1716's new `DisconnectProbeRuntime` in `HTTPServerClientDisconnectTests.swift` did not declare it. The declaration (`nil`) is squashed into M5.
- **SPEC-015 line 4** now depends on `SPEC-001 v1.9.24` (main's #1716 bump) instead of v1.9.23. This is squashed into "Refresh SPEC-015 dependency versions after M8".
- SPECs: #1690 does not touch SPEC-001, SPEC-038 or SPEC-039, so no versions needed stacking. `CONFORMANCE.json` and `specs/README.md` auto-merged as a union. `CONFORMANCE.json` has 0 non-ASCII bytes and is valid JSON.
- These auto-merged cleanly and were checked by the build and typecheck:
  - `InferenceRelay.swift`: #1716's queue-pressure `error_queue_full` mapping and #1690's `RelayStreamBatcher` lock (H6) are both present.
  - `ModelRuntime`, `ContinuousBatchScheduler`, `MacProviderCLI`, `Config`, `ChatCompletionRequest`, `MSBThroughputCommand`.
  - `HTTPServerReceiptTests`, `ServeCommandTests`.

## 3. The disconnect mechanism: one signal and one read pump

- **Signal (#1716).** `ClientDisconnectState` is set by `RouterHandler.channelInactive` for every in-flight request. It feeds `shouldCancel` and every post-generation or catch decision.
- **Read pump (#1690 `PeerCloseMonitor`, kept but narrowed).** It covers a case #1716 does not: a buyer who closes after the request's read burst.
  - `HTTPServerPipelineHandler` withholds reads while a response is in flight.
  - NIO on Darwin has `isEarlyEOFDeliveryWorkingOnThisOS == false` (`SelectorGeneric.swift`), so it delivers no EOF without a read. `channelInactive` would never fire, or would fire only when a write failed.
  - #1716's detection tests close right after sending, so their EOF is read in the same read loop and they pass either way.
- **Narrowed.** The monitor is installed only when the pipeline contains `HTTPServerPipelineHandler`.
  - Without that handler, reads continue and EOF already reaches `channelInactive`.
  - Pipelined requests must still reach the router. Otherwise #1716's `testPipelinedRequestsEachKeepTheirOwnDisconnectState` (pipelining assistance off) would lose its second request to the monitor's discard.
  - Its doc comment now says it is a pump only and that the signal is `ClientDisconnectState`.
- **Regression test added** (squashed into `45d0702c`): `testStreamingDisconnectDuringInferenceReachesShouldCancel`, with pipelining assistance on and a close after inference has started. It is typechecked only: XCTest cannot run on the Studio.
- **Lab evidence** (`lab-disconnect-probe.py`, direct HTTP to the lab serve on :19120, llama-server behind it, close at 0.8 s):
  - Non-streaming, `max_tokens` 1500: CBTrace shows `http_runtime_call`, then `http_channel_inactive armed=1` 803 ms later, then `http_catch_cancellation` 57 ms after that. The upstream request was cancelled and has no completed tap line. `errors_total` stayed at 12. The audit row is `pre_token_cancel`.
  - Streaming: same, `errors_total` unchanged.

## 4. Verification (Studio, `8eecfafe`)

- `swift build -c release --product macprovider-cli`: OK.
- Test typecheck against `xcstub`: 0 compile errors (the expected XCTest link failure only).
- Coordinator `go vet` and `go test -count=1 ./...`: rc=0.
- Gateway `go vet` and `go test -count=1 ./...`: rc=0.
- `check_spec_governance.py --base-ref origin/main`: passed. `gen_spec_index.py --check --lint`: ok.
- Log: `verify-rebase1716.log`.

## 5. Lab (M6 rig, `LAB=/Users/a1/lab-1690-m6/m8`, built from the HEAD export)

- The engine switches in the earlier M8 runs had left each engine's candidate `revoked` (`runtime_identity_drift`). Before each engine's cases, `lab-reprice-rebase1716.sh` ran a fresh offer and price, then restarted serve by pidguard identity. This is lab state only, not a code change.
- The pre-rebase captures were moved to `captures-m8-prerebase/`.
- llamacpp run (`paid concurrency engine_llamacpp_pool engine_llamacpp_global global`): 31/31 PASS.
- mlxlm run (`mlxlm_paid mlxlm_stream_after_change`): 21/21 PASS.
- Results: `rebase1716-lab-{llamacpp,mlxlm}-results.txt`.
- Teardown was `rig.sh down` by pidguard identity. No 191xx listeners were left. The live PID 811 on :8080 was untouched (etime 4h53m).
