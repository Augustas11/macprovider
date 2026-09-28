# Audit R1 — security

Scope: full `origin/main...HEAD` diff under `phase3-binary/`, plus the relay,
HTTP receipt, receipt-builder, coordinator settlement, and cited specification
paths.

Method: first-party source review and existing targeted tests only. No malformed
payloads were authored or constructed. No code was changed.

## Findings

No CRITICAL, HIGH, MEDIUM, or LOW security findings were identified.

Severity summary: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0, INFO 0.

### Receipt content is bound to delivered stream content

- Serial streaming uses `textEmitter.emittedContent` for the non-Harmony
  `CompletionResult.content` ([ModelRuntime.swift:6418-6419](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6418)).
  The emitter records exactly each content delta passed to `onChunk`, while
  tool-call rows are kept in the separate tool-call field.
- Continuous-batch streaming performs the same rebinding from
  `state.emittedContent` before structured-output validation
  ([ModelRuntime.swift:4662-4684](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4662)).
- The speculative streaming branch sends and returns the same accumulated
  `emittedText` ([ModelRuntime.swift:6209-6213](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6209)).
- Normal completion, structured-error, and failed-generation paths do not
  produce a successful settlement receipt from an unvalidated partial result.

### Cancellation and tool rows fail closed when delivery cannot be reconstructed

For a relay cancellation, the receipt path obtains content only from frames
accepted by the stream batcher and confirmed sent to the buyer
([InferenceRelay.swift:1091-1100](../../phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1091)).
It passes that prefix to receipt construction ([InferenceRelay.swift:1108-1123](../../phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1108)); an
unknown delivery state is omitted rather than signed. When a tool-call delta
has opened, the batcher suppresses later content and refuses to reconstruct a
content-only cancellation prefix ([InferenceRelay.swift:1611-1624](../../phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1611));
its `deliveredContent` result is then unavailable for signing
([InferenceRelay.swift:1643-1649](../../phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1643)).
This prevents a receipt from claiming content or usage that the buyer could
not have received.

### Cleanup rewriting does not bypass tool or stop gates

The emitter receives the already-filtered streaming safe prefix, and content
after a tool-call boundary is suppressed before it can reach the relay batcher.
The structured accumulator is updated from the same emitted deltas used for
the completion content. Re-anchoring therefore changes only which already
delivered-safe suffix is emitted; it does not reintroduce filtered or
tool-suppressed text.

### Usage and settlement hash binding remain consistent

`ReceiptBuilder` computes canonical settlement content, delivered-byte length,
and the output hash from the same content/tool-call/terminal tuple used for the
receipt ([ReceiptBuilder.swift:367-394](../../phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:367)).
The coordinator rejects a mismatching signed output hash
([settlement_verifier.go:287-293](../../phase4-coordinator/internal/billing/settlement_verifier.go:287)).
The signed settlement string can differ from raw wire bytes only through the
existing normative CRLF/CR-to-LF and NFC canonicalization, which the buyer-side
settlement tracker applies before recomputing the same tuple; this is not a
rewrite-path discrepancy.
For cancellation, usage is reduced to the delivered prefix when an attested
prefix-token table exists; otherwise the completion is marked unattested and
the receipt path omits settlement. No changed path signs generated-token usage
for an unreconstructable delivered prefix.

### MLX cache clearing

The new helper is a single direct `Memory.clearCache()` call
([ModelRuntime.swift:1864-1868](../../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1864)).
It is invoked after `TokenIterator` construction on serial complete,
speculative, and serial streaming paths. Continuous batching remains on its
existing scheduler path. Static review found no receipt, content, or KV-state
mutation caused by these calls. A hardware concurrency campaign was not run on
this host because MacProvider hardware verification is restricted to the
designated Mac Studio; that is a validation limit, not a confirmed defect.

## Validation

All commands were run from `phase3-binary/` except the diff check:

- `git diff --check origin/main...HEAD -- phase3-binary/` — passed.
- `swift test --filter StreamingEmitterCleanupRewriteTests` — 7 passed.
- `swift test --filter ContinuousBatchToolStructuredRowTests` — 20 passed.
- `swift test --filter ModelRuntimePromptContextTests` — 6 passed.
- `swift test --filter ServingKnobsConfigTests` — 109 passed, 1 skipped because
  the MLX default metallib is unavailable on this host.

Repository-wide CI, full Swift tests, and hardware-backed concurrency tests
were not run under the MacProvider local-host boundary.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW
