# Audit R2 — code

Scope: full `origin/main...HEAD` diff under `phase3-binary/`, with surrounding
provider, coordinator, and normative-spec code read as needed. This is a
source-and-existing-test review; no malformed payloads were constructed.

## Findings

### MEDIUM-1 — Cleanup-aware re-anchoring does not cover streamed tool arguments

- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:8402-8405,8505-8511`; fallback adapter at `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:61-75`.
- Failure condition: cleanup-enabled decoding is used for a streamed tool call whose valid JSON `function.arguments` contains a string value crossing a tokenizer cleanup boundary. A cumulative decoded prefix can first expose the pre-cleanup spelling and later expose the cleaned spelling, so the later arguments string is no longer prefixed by the already-emitted arguments.
- Evidence: the native emitter emits only `delta(from:emittedArguments,to:arguments)` and deliberately returns an empty delta for a non-prefix replacement. The OpenAI fallback likewise skips the call when `call.arguments.hasPrefix(already)` is false. The upstream tokenizer cleanup is global over decoded text, so the same deterministic cleanup rules can occur inside a JSON string value. The final parser can still have valid complete arguments, while the buyer-visible stream has a truncated argument sequence; the completion/receipt path uses the final parsed tool call rather than emitting a replacement for bytes already sent. This violates SPEC-018 §8.4 tool-argument parity even when settlement later fails closed because the tracker cannot reconstruct the call.
- Fix: make tool-argument streaming cleanup-aware as well: hold back a cleanup-rewrite-capable suffix until stable, or use a dedicated incremental argument pipeline that never emits a prefix which can later change, and flush the final stable argument text at termination. Add valid cleanup-boundary coverage through native serial streaming, continuous-batch streaming, and the relay/HTTP settlement reconstruction path.

### INFO-1 — The new golden fixture is not an end-to-end public stream/receipt proof

- Location: `phase3-binary/Tests/macprovider-cliTests/StreamingSettlementBindingTests.swift:8-29,125-231`; `phase4-coordinator/internal/buyer/settlement_output_test.go:13-75`.
- Failure condition: a future adapter, callback, cancellation, tool-row, structured-error, speculative, or HTTP/relay receipt branch bypasses the corrected emitter content while the local emitter and coordinator tracker unit tests remain green. The fixture would not detect that integration mismatch.
- Evidence: the Swift test directly constructs `SerialStreamingTextEmitter` and `AttachedPagedKVStreamState`; the Go test directly feeds fixture deltas to `newSettlementStreamOutputTracker`. Neither invokes `ModelRuntime.stream`, `InferenceRelay`, `HTTPServer`, or a real provider-to-coordinator receipt handoff. The fixture therefore closes the value-level binding example and independently verifies the canonical hash, but not the complete delivery chain or every `CompletionResult` producer.
- Fix: add a small valid-response integration harness that drives the public serial and continuous-batch stream adapters into the actual relay/HTTP receipt binding, with separate existing-path coverage for cancellation, tool rows, structured errors, speculative output, and terminal flush behavior.

## R1/R2 closure checks

- Content re-anchoring now uses longest-common-scalar-prefix behavior and retains only an immutable emitted suffix for cleanup rewrites. Stop-token holdback, UTF-8 tail holdback, structured accumulation, and terminal flush are covered by the new tests; no loss or duplication was found in those paths.
- The no-rewrite path remains prefix-based, so unchanged decoded content preserves byte identity. Continuous-batch rows use the same incremental cleanup pipeline and bind `CompletionResult.content` to emitted deltas.
- Serial, continuous-batch, and speculative streamed completions now bind non-Harmony settlement content to delivered content. Harmony remains on its dedicated parser path.
- `Memory.clearCache()` is invoked once after iterator initialization on serial complete, serial streaming, and speculative paths; continuous batching remains intentionally unchanged. No new cross-row cache race was found in the reviewed code.
- `preserve_thinking` is gated on templates supporting both `enable_thinking` and `preserve_thinking`, and follows the existing artifact-aware capability plumbing. No warm-switch or snapshot inconsistency was found.
- SPEC-018 v0.2.10, SPEC-019 v0.2.6, and SPEC-015 §N.5 now consistently define delivered delta concatenation as the streaming settlement domain, while retaining exact parity for tool arguments and Harmony. A repository-wide spec search found no contradictory assistant-content parity restatement.

## Validation

- `swift test --filter 'StreamingEmitterCleanupRewriteTests|StreamingSettlementBindingTests|ContinuousBatchToolStructuredRowTests|ModelRuntimePromptContextTests|ServingKnobsConfigTests'` — 148 executed, 1 skipped for unavailable MLX default metallib, 0 failures.
- `swift test --filter 'NativeToolCallStreamEmitterTests|ModelRuntimeStructuredOutputTests|StreamingValidationFailureTests'` — 33 executed, 0 failures.
- `go test ./internal/buyer -run 'TestSettlementStreamCleanupRewriteGoldenBindsDeliveredBytes|TestTerminalStateFromAttemptCoversReceiptTerminalStates|TestSettlementStreamOutputQuarantinesIncompleteToolCall|TestSettlementStreamOutputLatchesDoneAndRejectsPostDoneData|TestSettlementOutputRejectsDuplicateJSONKeys|TestSettlementOutputRejectsDuplicateToolArgumentKeys|TestSettlementStreamOutputQuarantinesDuplicateToolArgumentKeys' -count=1` — passed.
- `git diff --check origin/main...HEAD -- phase3-binary/` — passed.
- Full repository/CI-parity and hardware checks were not run because this operator Mac is outside the repository's MacProvider resource and hardware boundaries.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 0 LOW
