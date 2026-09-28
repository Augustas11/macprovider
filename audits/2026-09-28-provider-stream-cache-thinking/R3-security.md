# Audit R3 — security

Scope: full `origin/main...HEAD` provider diff, including the native-MTP/continuous-batch path and the surrounding relay, loopback, receipt, coordinator, and normative-spec code. I used source inspection and existing targeted tests only; I did not construct malformed payloads.

## Findings

### HIGH — normal relay receipts are not bound to the bytes delivered for a tool stream

Files: `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:708-713, 576-588`; `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1076-1085, 1151-1155, 1191-1205, 1602-1620`; `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:367-405`.

Failure condition: a pool-authorized loopback stream contains assistant content after the first tool-call delta. The loopback accumulator appends every upstream content delta to `CompletionResult.content`. The relay batcher deliberately suppresses content after `emittedToolCall` and therefore does not put those bytes on the buyer wire, but the normal-completion receipt is built from the unmodified `completion` rather than from an exact snapshot of the batcher's accepted/sent content. The signed settlement tuple can consequently hash content that the buyer did not receive. The coordinator later detects the discrepancy as `output_hash_mismatch` (`phase4-coordinator/internal/billing/settlement_verifier.go:287-293`), but the provider has already emitted an invalid money-path receipt and reports usage for a different output domain.

Fix: bind the normal relay receipt to a batcher snapshot of the exact content and tool-call bytes accepted and sent to the buyer, and fail closed without a receipt whenever equality with the final completion cannot be proven. The same binding must be used before `buildReceiptHeader` on the complete path, not only by `deliveredContent` on cancellation.

### INFO — the successful loopback-to-relay receipt path lacks the regression that would catch this

The new tests cover emitter/continuous-batch golden bytes (`StreamingSettlementBindingTests.swift:8`), tool-argument final-close failure (`InferenceRelayTests.swift:666`), cancellation's deliberate `nil` content after a tool call (`InferenceRelayTests.swift:1929`), and a pool-authorized non-streaming loopback receipt (`HTTPServerReceiptTests.swift:1716`). They do not exercise a successful normal relay stream in which the loopback accumulator has post-tool content while `RelayStreamBatcher` suppresses it. Add a fixture-based success-path assertion that the receipt's settlement content equals the buyer-visible concatenation, without requiring malformed-payload generation in the audit.

## Closure and coverage checks

- R1's content-binding, cancellation-prefix, cleanup-smuggling, usage, and cache-safety concerns are closed for the provider emitter paths inspected. Cancellation receipts use only `deliveredContent`; tool-call cancellation remains unattested rather than signed.
- R2's tool-argument mismatch concern is closed by cleanup-pattern holdback plus `StreamedToolCallArgs.finalDeltas` prefix/identity checks and the final-close failure path. The remaining HIGH above is the separate relay-level content binding gap on normal completion.
- Serial, continuous-batch, speculative, and native-MTP streaming share `SerialStreamingTextEmitter`/`AttachedPagedKVStreamState` and `finishContinuousBatchStream`; no native-MTP streaming bypass was found. Cleanup holdback runs before tool observation, stop/UTF-8 holdbacks are flushed at finish, and structured-output accumulation uses the emitted deltas.
- `Memory.clearCache()` is called after iterator initialization on serial, streaming, and speculative paths; no unsynchronized receipt/content state is shared with other rows, and continuous batching intentionally retains its existing cache lifecycle. I found no security defect in this change.
- Grep of the current SPEC-015 §N.5, SPEC-018 v0.2.10 §3.10/§8.4, SPEC-019 v0.2.6, and other streaming-parity restatements found the code's delivered-delta and byte-equivalence rules consistent. No normative-spec change is required for this finding; the relay implementation needs to honor the existing rule.

## Validation

- `swift test --filter 'StreamingEmitterCleanupRewriteTests|StreamingSettlementBindingTests|ContinuousBatchToolStructuredRowTests|NativeToolCallStreamEmitterTests|ModelRuntimeStructuredOutputTests|StreamingValidationFailureTests|InferenceRelayTests|HTTPServerReceiptTests'`: 144 tests passed, 0 failures.
- `go test ./internal/buyer -run 'TestSettlementStreamCleanupRewriteGoldenBindsDeliveredBytes|TestSettlementStreamOutputQuarantinesIncompleteToolCall|TestSettlementStreamOutputLatchesDoneAndRejectsPostDoneData|TestSettlementOutputRejectsDuplicateJSONKeys|TestSettlementStreamOutputQuarantinesDuplicateToolArgumentKeys' -count=1`: passed.
- `git diff --check origin/main...HEAD -- phase3-binary/`: passed.
- Full CI, full Swift/Go suites, and hardware acceptance were not run because the MacProvider host boundary reserves those workloads for GitHub Actions/designated Mac Studio.

VERDICT: 0 CRITICAL, 1 HIGH, 0 MEDIUM, 0 LOW
